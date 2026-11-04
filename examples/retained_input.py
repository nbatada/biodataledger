"""Small helpers for a new retained-input workflow."""


def load_retained_input(project, loader, *, ref=None, purpose=None, verify="sha256"):
    """Return ``(native_object, resolved_source)`` for one exact selection."""
    if (ref is None) == (purpose is None):
        raise ValueError("choose exactly one of ref or purpose")
    if not callable(loader):
        raise TypeError("loader must be callable")
    source = project.resolve_data(ref=ref, purpose=purpose, verify=verify)
    return loader(source.path), source


def load_selected_redraw_input(project, jobs, requested_job, loader, *, verify="sha256"):
    """Choose one declared job before loading its sole input.

    Each jobs value is ``{"ref": ...}`` or ``{"purpose": ...}``; other jobs
    are neither resolved nor passed to the loader.
    """
    if requested_job not in jobs:
        raise ValueError("requested job is not declared")
    selector = jobs[requested_job]
    if not isinstance(selector, dict):
        raise TypeError("job selector must be a mapping")
    return load_retained_input(project, loader, verify=verify, **selector)


def register_redraw(project, source, *, name, figure_path, figure_type, code, method, params):
    """Register one saved redraw against the source resolved for this session."""
    analysis = project.register_analysis(name, inputs=[source.ref], code=code,
                                         method=method, params=params)
    figure = project.register_figure(
        figure_path, type=figure_type, analysis=analysis,
        figure_sources={"rendering_inputs": [source.ref], "relationship": "declared"})
    return {"analysis": analysis, "figure": figure, "source": source}
