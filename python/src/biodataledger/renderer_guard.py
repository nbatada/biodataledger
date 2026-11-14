"""Opt-in ordinary API guard and locally observed native rendering receipts."""
import copy
from datetime import datetime
import inspect
import math
from pathlib import Path
import re
import shutil
import tempfile

from .core import CONTEXT_VERSION, BundleError, fingerprint, now, require, validate_values

POLICY = "approved_renderers_v1"
KEY = "renderer_receipt"
VERSION = "biodataledger-renderer/1"
RENDERERS = {"pca", "umap_split", "violin_qc", "group_comparison", "heatmap", "volcano", "ma"}
SINGLE_AXIS = RENDERERS - {"umap_split"}
MESSAGE = ("APPROVED_RENDERER_REQUIRED: use render_figure(renderer=..., data=..., "
           "plot_args=...) with an approved BioDataLedger renderer")
FIELDS = {"version", "renderer", "backend", "package_version", "rendered_at", "output_sha256",
          "implementation_sha256", "plot_args", "panels", "export_settings", "verification", "scientific_acceptance"}


def refuse_direct(project):
    require(project.figure_policy() != POLICY, MESSAGE)


def reserve(details):
    require(KEY not in details, "renderer_receipt is reserved; " + MESSAGE)


def _validate_export(settings):
    require(isinstance(settings, dict) and set(settings) == {"format", "width", "height", "units", "dpi"},
            "invalid renderer export_settings fields")
    require(settings["units"] == "in" and isinstance(settings["format"], str)
            and settings["format"] in {"png", "pdf", "svg"}, "export format must be png, pdf or svg with units='in'")
    for field, limit in (("width", 100), ("height", 100), ("dpi", 2400)):
        value = settings[field]
        require(type(value) in (int, float) and math.isfinite(value) and 0 < value <= limit,
                field + " must be finite, positive and <= " + str(limit))
    require(settings["width"] * settings["height"] * settings["dpi"] ** 2 <= 100_000_000,
            "render dimensions exceed 100 million pixels")


def validate_receipt(rec, schema_version):
    if KEY not in rec["details"]:
        return
    receipt = rec["details"][KEY]
    require(rec["kind"] == "figure" and schema_version == CONTEXT_VERSION,
            "renderer_receipt requires schema 0.4.0 FIG")
    require(isinstance(receipt, dict) and set(receipt) == FIELDS, "invalid renderer_receipt fields")
    require(receipt["version"] == VERSION and isinstance(receipt["renderer"], str)
            and receipt["renderer"] in RENDERERS | {"compose"},
            "invalid renderer_receipt version/renderer")
    require(receipt["backend"] in ("matplotlib", "ggplot2") and isinstance(receipt["package_version"], str)
            and receipt["package_version"].strip(), "invalid renderer_receipt backend/package_version")
    stamp = receipt["rendered_at"]
    require(isinstance(stamp, str) and re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z", stamp),
            "invalid renderer_receipt rendered_at")
    try:
        datetime.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError as exc:
        raise BundleError("invalid renderer_receipt rendered_at") from exc
    for field in ("output_sha256", "implementation_sha256"):
        require(isinstance(receipt[field], str) and re.fullmatch(r"[0-9a-f]{64}", receipt[field]),
                "invalid renderer_receipt " + field)
    require(receipt["output_sha256"] == rec["sha256"] and rec["size"] is not None,
            "renderer_receipt output hash/size binding mismatch")
    _validate_export(receipt["export_settings"])
    require(receipt["export_settings"]["format"] == rec["details"].get("format"),
            "renderer_receipt export format binding mismatch")
    require(isinstance(receipt["plot_args"], dict), "renderer_receipt plot_args must be an object")
    require(isinstance(receipt["panels"], list), "renderer_receipt panels must be an array")
    panels = receipt["panels"]
    require(bool(panels) == (receipt["renderer"] == "compose"), "invalid renderer_receipt panels")
    for panel in panels:
        require(isinstance(panel, dict) and set(panel) == {"renderer", "plot_args"}
                and isinstance(panel["renderer"], str) and panel["renderer"] in SINGLE_AXIS
                and isinstance(panel["plot_args"], dict),
                "invalid renderer_receipt panel")
    require(receipt["verification"] == "local_render_observed"
            and receipt["scientific_acceptance"] == "not_assessed", "invalid renderer_receipt evidence")


def guard_update(project, rec, changes):
    if "details" in changes:
        details = changes["details"]
        require(isinstance(details, dict), "details must be an object")
        if KEY in rec["details"]:
            require(KEY in details and details[KEY] == rec["details"][KEY],
                    "renderer_receipt is immutable; " + MESSAGE)
        else:
            reserve(details)
    if project.figure_policy() == POLICY and rec["kind"] == "figure":
        from .presentation import presentation_only_change
        require(set(changes) <= {"name", "status", "details"}, MESSAGE)
        require("details" not in changes or presentation_only_change(rec, {"details": changes["details"]}), MESSAGE)


def _arguments(pl, renderer, value):
    value = {} if value is None else value
    require(type(value) is dict, "plot_args must be a plain named mapping; " + MESSAGE)
    try:
        validate_values(value)
    except BundleError as exc:
        raise BundleError(str(exc) + "; " + MESSAGE) from exc
    allowed = set(inspect.signature(getattr(pl, renderer)).parameters) - {"table", "matrix", "ax", "panels", "figsize"}
    require(set(value) <= allowed, "unsupported plot_args (no data, axes, plots, files or callbacks); " + MESSAGE)
    return copy.deepcopy(value)


def _data(value, pl):
    require(isinstance(value, (dict, list, tuple, pl.pd.DataFrame, pl.np.ndarray)),
            "data must be a prepared table or matrix; " + MESSAGE)
    return value


def render_figure(project, renderer, *, data=None, plot_args=None, panels=None, analysis=None,
                  name=None, format="png", width=6, height=4, dpi=300):
    require(isinstance(renderer, str) and renderer in RENDERERS | {"compose"}, MESSAGE)
    export = {"format": format, "width": width, "height": height, "units": "in", "dpi": dpi}
    _validate_export(export)
    if name is not None:
        require(isinstance(name, str) and name.strip(), "name must be nonblank text")
    if analysis is not None:
        project._record(analysis, "analysis")
    from . import pl, __version__
    args = _arguments(pl, renderer, plot_args)
    specifications = []
    if renderer == "compose":
        require(data is None and type(panels) is list and panels, "compose requires nonempty declarative panels; " + MESSAGE)
        for panel in panels:
            require(type(panel) is dict and set(panel) <= {"renderer", "data", "plot_args"}
                    and {"renderer", "data"} <= set(panel)
                    and isinstance(panel["renderer"], str) and panel["renderer"] in SINGLE_AXIS,
                    "compose panels require an approved single-axis renderer and data; " + MESSAGE)
            specifications.append((panel["renderer"], _data(panel["data"], pl),
                                   _arguments(pl, panel["renderer"], panel.get("plot_args"))))
    else:
        require(panels is None, "panels are supported only for compose")
        _data(data, pl)
    before = copy.deepcopy(project.state), project._dirty, copy.deepcopy(project._snapshots)
    existing_figures = set(pl.plt.get_fignums())
    folder = None
    base_created = False
    try:
        base = project._internal(".nb_project_bundle/outputs")
        try:
            base.mkdir()
            base_created = True
        except FileExistsError:
            require(base.is_dir(), "managed output parent must be a directory")
        folder = Path(tempfile.mkdtemp(prefix="render-", dir=base))
        destination = folder / ("figure." + format)
        if renderer == "compose":
            callbacks = [lambda ax, r=r, d=d, a=a: getattr(pl, r)(d, ax=ax, **a)
                         for r, d, a in specifications]
            figure = pl.compose(callbacks, figsize=(width, height), **args)
        else:
            plot = getattr(pl, renderer)(data, **args)
            figure = plot.figure if hasattr(plot, "figure") else plot
            figure.set_size_inches(width, height)
        with destination.open("xb") as stream:
            figure.savefig(stream, format=format, dpi=dpi)
        rec = project._figure_record(destination, renderer, analysis=analysis, name=name or renderer)
        rec["details"][KEY] = {
            "version": VERSION, "renderer": renderer, "backend": "matplotlib", "package_version": __version__,
            "rendered_at": now(), "output_sha256": rec["sha256"],
            "implementation_sha256": fingerprint(pl.__file__), "plot_args": args,
            "panels": [{"renderer": r, "plot_args": a} for r, _, a in specifications],
            "export_settings": export,
            "verification": "local_render_observed", "scientific_acceptance": "not_assessed"}
        return project._stage(rec, "render_figure", version=CONTEXT_VERSION)
    except BaseException:
        project.state, project._dirty, project._snapshots = before
        project._reindex()
        if folder is not None:
            shutil.rmtree(folder)
        if base_created:
            try:
                base.rmdir()
            except OSError:
                pass  # Preserve any contents concurrently added by another writer.
        raise
    finally:
        for number in set(pl.plt.get_fignums()) - existing_figures:
            pl.plt.close(number)
