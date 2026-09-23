class ReleaseError(RuntimeError):
    """Base fail-closed release error."""


class ContractError(ReleaseError):
    pass


class SourceAttestationError(ReleaseError):
    pass


class ToolchainError(ReleaseError):
    pass


class ArtifactError(ReleaseError):
    pass


class ProcessError(ReleaseError):
    pass


class StateError(ReleaseError):
    pass
