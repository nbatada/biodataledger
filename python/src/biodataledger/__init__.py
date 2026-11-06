"""A local project bookkeeper. Importing performs no project I/O."""
from .core import ProjectBundle, BundleError

__version__ = "0.17.0"
__all__ = ["ProjectBundle", "BundleError"]
