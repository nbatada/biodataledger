"""A local project bookkeeper. Importing performs no project I/O."""
from .core import ProjectBundle, BundleError

__version__ = "0.12.1"
__all__ = ["ProjectBundle", "BundleError"]
