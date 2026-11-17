"""A local project bookkeeper. Importing performs no project I/O."""
from .core import ProjectBundle, BundleError

__version__ = "0.20.0"
__all__ = ["ProjectBundle", "BundleError"]


def __getattr__(name):
    if name == "pl":
        from importlib import import_module
        module = import_module(".pl", __name__)
        globals()[name] = module
        return module
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
