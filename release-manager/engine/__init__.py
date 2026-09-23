"""ENV-1b core release engine. Production process adapters are intentionally absent."""

from .core import Candidate, MigrationApprovalReceipt, MigrationGateRequired, ReleaseEngine, ReleaseRequest
from .fake_adapter import FakeProcessAdapter, FakeProcessRuntime
from .pm2_adapter import PM2ProcessAdapter
from .ports import AdapterHandle, FakeLifecycleRunner, FakeSourceProvider
from .state_store import AtomicStateStore, GenerationConflict
from .legacy_restore import LoadedLegacyRestoreDescriptor, load_legacy_restore_descriptor

__all__ = [
    "AdapterHandle",
    "AtomicStateStore",
    "Candidate",
    "FakeLifecycleRunner",
    "FakeProcessAdapter",
    "FakeProcessRuntime",
    "FakeSourceProvider",
    "GenerationConflict",
    "MigrationGateRequired",
    "MigrationApprovalReceipt",
    "LoadedLegacyRestoreDescriptor",
    "PM2ProcessAdapter",
    "ReleaseEngine",
    "ReleaseRequest",
    "load_legacy_restore_descriptor",
]
