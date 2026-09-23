/** ENV-1b-a specification only. This file contains no production implementation. */

declare const processHandleBrand: unique symbol;

export interface PersistedProcessHandle {
  readonly apiVersion: "quanyu.ai/process-handle/v1alpha1";
  readonly kind: "ProcessHandle";
  readonly adapter: {
    readonly kind: string;
    readonly version: string;
    readonly instanceId: string;
  };
  readonly identity: {
    readonly environmentId: string;
    readonly serviceId: string;
    readonly namespace: string;
    readonly adapterId: string;
    readonly pid: number;
    readonly processStartId: string;
  };
  readonly runtime: {
    readonly executable: string;
    readonly args: readonly string[];
    readonly cwd: string;
  };
  readonly releaseSha: string;
  readonly invocationFingerprint: `sha256:${string}`;
  readonly configurationDigests?: { readonly build: `sha256:${string}`; readonly runtime: `sha256:${string}` };
  readonly legacyRestoreDescriptorDigest?: `sha256:${string}`;
  readonly provenance: {
    readonly origin: "observed" | "started";
    readonly observationId: string;
    readonly observedAt: string;
    readonly adapterReceipt: string;
  };
}

/** Only an adapter observation/start/restore result may carry this brand. */
export type ProcessHandle = PersistedProcessHandle & {
  readonly [processHandleBrand]: "adapter-observed-or-started";
};

export interface ProcessInventory {
  readonly observedAt: string;
  readonly records: readonly PersistedProcessHandle[];
}

export interface ProcessAdapter {
  inventory(service: unknown): Promise<ProcessInventory>;
  validatePolicy(policy: unknown): Promise<void>;
  preflightLegacyRestore(descriptor: unknown): Promise<unknown>;
  observeLegacy(descriptor: unknown): Promise<ProcessHandle>;
  assertReplaceable(current: ProcessHandle, candidate: unknown): Promise<void>;
  stopExact(handle: ProcessHandle): Promise<void>;
  deleteExact(handle: ProcessHandle): Promise<void>;
  awaitAbsent(handle: ProcessHandle): Promise<unknown>;
  startCandidate(spec: unknown): Promise<ProcessHandle>;
  attest(handle: ProcessHandle, expected: unknown): Promise<unknown>;
  restore(handle: ProcessHandle): Promise<ProcessHandle>;
  persist(attested: ProcessHandle): Promise<unknown>;
}

/** State mutation is deliberately absent from ProcessAdapter. */
export interface ReleaseStateWriter {
  allocateAttempt(expectedGeneration: number): Promise<unknown>;
  commitAttestedState(expectedGeneration: number, record: unknown): Promise<unknown>;
  recordTerminalFailure(expectedGeneration: number, evidence: unknown): Promise<unknown>;
}
