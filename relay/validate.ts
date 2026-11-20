// Pure validation helpers for the relay: payload shape checks, Ed25519
// register-signature verification and discover filtering. Kept free of Bun
// globals so they can be unit-tested in isolation.

export type JSONValue =
  | string
  | number
  | boolean
  | null
  | JSONValue[]
  | { [key: string]: JSONValue };

export type JSONObject = { [key: string]: JSONValue };

export function isObject(value: unknown): value is JSONObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

// ── Register ────────────────────────────────────────────────────────

export type RegisterPayload = {
  nodeID: string;
  publicKey: string;
  wgPublicKey?: string;
  displayName: string;
  capabilities: JSONObject;
  signature: string;
};

/** Shape-check a register payload. Returns the typed payload or an error string. */
export function parseRegister(raw: unknown): RegisterPayload | string {
  if (!isObject(raw)) return "register payload must be a JSON object";
  const { nodeID, publicKey, wgPublicKey, displayName, capabilities, signature } = raw;
  if (typeof nodeID !== "string" || nodeID.length === 0) return "Missing nodeID in register payload";
  if (typeof publicKey !== "string") return "Missing publicKey in register payload";
  if (typeof signature !== "string") return "Missing signature in register payload";
  if (wgPublicKey !== undefined && wgPublicKey !== null && typeof wgPublicKey !== "string") {
    return "wgPublicKey must be a string";
  }
  if (displayName !== undefined && displayName !== null && typeof displayName !== "string") {
    return "displayName must be a string";
  }
  if (!isObject(capabilities)) return "capabilities must be a JSON object";
  return {
    nodeID,
    publicKey,
    wgPublicKey: typeof wgPublicKey === "string" ? wgPublicKey : undefined,
    displayName: typeof displayName === "string" ? displayName : "",
    capabilities,
    signature,
  };
}

const HEX_RE = /^[0-9a-fA-F]*$/;

/** Decode a hex string (either case). Returns null for odd length or non-hex input. */
export function hexToBytes(hex: string): Uint8Array | null {
  if (hex.length % 2 !== 0 || !HEX_RE.test(hex)) return null;
  const out = new Uint8Array(hex.length / 2);
  for (let i = 0; i < out.length; i++) {
    out[i] = parseInt(hex.substring(i * 2, i * 2 + 2), 16);
  }
  return out;
}

function toArrayBuffer(bytes: Uint8Array): ArrayBuffer {
  const copy = new ArrayBuffer(bytes.byteLength);
  new Uint8Array(copy).set(bytes);
  return copy;
}

export type SignatureCheck = { ok: true } | { ok: false; reason: string };

/**
 * Verify a relay register signature (contract C):
 *   - nodeID == publicKey (case-insensitive), both hex of a 32-byte Ed25519 key
 *   - signature = hex(Ed25519.sign(utf8(nodeID))) with that key
 * The signed message is the nodeID string exactly as sent.
 */
export async function verifyRegisterSignature(
  nodeID: string,
  publicKey: string,
  signature: string,
): Promise<SignatureCheck> {
  if (nodeID.toLowerCase() !== publicKey.toLowerCase()) {
    return { ok: false, reason: "nodeID must equal publicKey" };
  }
  const key = hexToBytes(publicKey);
  if (!key || key.length !== 32) {
    return { ok: false, reason: "publicKey must be 64 hex characters (32-byte Ed25519 key)" };
  }
  const sig = hexToBytes(signature);
  if (!sig || sig.length !== 64) {
    return { ok: false, reason: "signature must be 128 hex characters (64-byte Ed25519 signature)" };
  }
  try {
    const cryptoKey = await crypto.subtle.importKey(
      "raw",
      toArrayBuffer(key),
      { name: "Ed25519" },
      false,
      ["verify"],
    );
    const valid = await crypto.subtle.verify(
      { name: "Ed25519" },
      cryptoKey,
      toArrayBuffer(sig),
      toArrayBuffer(new TextEncoder().encode(nodeID)),
    );
    return valid ? { ok: true } : { ok: false, reason: "signature does not verify for this publicKey" };
  } catch (e) {
    return { ok: false, reason: `signature verification failed: ${e}` };
  }
}

// ── Targeted (peer-to-peer) messages ────────────────────────────────

export type TargetedPayload = JSONObject & {
  toNodeID: string;
  sessionID: string;
};

/** Shape-check offer/answer/iceCandidate/relay* payloads. */
export function parseTargeted(kind: string, raw: unknown): TargetedPayload | string {
  if (!isObject(raw)) return `${kind} payload must be a JSON object`;
  if (typeof raw.toNodeID !== "string" || raw.toNodeID.length === 0) {
    return `${kind} requires a string toNodeID`;
  }
  if (typeof raw.sessionID !== "string") return `${kind} requires a string sessionID`;
  if (raw.fromNodeID !== undefined && typeof raw.fromNodeID !== "string") {
    return `${kind} fromNodeID must be a string`;
  }
  return raw as TargetedPayload;
}

// ── Discover ────────────────────────────────────────────────────────

export type DiscoverFilter = {
  modelID?: string;
  minRAMGB?: number;
  minTier?: number;
  maxPeers?: number;
};

export type DiscoverRequest = {
  requestingNodeID?: string;
  filter: DiscoverFilter;
};

function optional<T>(
  obj: JSONObject,
  key: string,
  check: (v: JSONValue) => v is T & JSONValue,
): T | undefined | Error {
  const value = obj[key];
  if (value === undefined || value === null) return undefined;
  return check(value) ? value : new Error(`filter.${key} has the wrong type`);
}

const isString = (v: JSONValue): v is string => typeof v === "string";
const isFiniteNumber = (v: JSONValue): v is number => typeof v === "number" && Number.isFinite(v);
const isPositiveInt = (v: JSONValue): v is number => typeof v === "number" && Number.isInteger(v) && v > 0;

/** Shape-check a discover payload (payload and filter are both optional). */
export function parseDiscover(raw: unknown): DiscoverRequest | string {
  if (raw === undefined || raw === null) return { filter: {} };
  if (!isObject(raw)) return "discover payload must be a JSON object";
  if (raw.requestingNodeID !== undefined && typeof raw.requestingNodeID !== "string") {
    return "requestingNodeID must be a string";
  }
  const requestingNodeID = typeof raw.requestingNodeID === "string" ? raw.requestingNodeID : undefined;
  const rawFilter = raw.filter;
  if (rawFilter === undefined || rawFilter === null) return { requestingNodeID, filter: {} };
  if (!isObject(rawFilter)) return "filter must be a JSON object";

  const modelID = optional(rawFilter, "modelID", isString);
  const minRAMGB = optional(rawFilter, "minRAMGB", isFiniteNumber);
  const minTier = optional(rawFilter, "minTier", isFiniteNumber);
  const maxPeers = optional(rawFilter, "maxPeers", isPositiveInt);
  for (const v of [modelID, minRAMGB, minTier, maxPeers]) {
    if (v instanceof Error) return v.message;
  }
  const filter: DiscoverFilter = {};
  if (typeof modelID === "string") filter.modelID = modelID;
  if (typeof minRAMGB === "number") filter.minRAMGB = minRAMGB;
  if (typeof minTier === "number") filter.minTier = minTier;
  if (typeof maxPeers === "number") filter.maxPeers = maxPeers;
  return { requestingNodeID, filter };
}

/**
 * Does a peer's advertised capabilities satisfy the filter?
 *   modelID  -> capabilities.loadedModels contains it
 *   minRAMGB -> capabilities.hardware.totalRAMGB >= value
 *   minTier  -> 1 <= capabilities.hardware.tier <= value (tier 1 is the most capable)
 * maxPeers is applied by the caller after filtering.
 */
export function peerMatchesFilter(capabilities: JSONValue, filter: DiscoverFilter): boolean {
  const caps = isObject(capabilities) ? capabilities : {};
  const hardware = isObject(caps.hardware) ? caps.hardware : {};
  if (filter.modelID !== undefined) {
    const models = Array.isArray(caps.loadedModels) ? caps.loadedModels : [];
    if (!models.includes(filter.modelID)) return false;
  }
  if (filter.minRAMGB !== undefined) {
    const ram = hardware.totalRAMGB;
    if (typeof ram !== "number" || ram < filter.minRAMGB) return false;
  }
  if (filter.minTier !== undefined) {
    const tier = hardware.tier;
    if (typeof tier !== "number" || tier < 1 || tier > filter.minTier) return false;
  }
  return true;
}

/** Uniform random sample of at most `max` items (order not preserved). */
export function samplePeers<T>(items: T[], max: number | undefined): T[] {
  if (max === undefined || items.length <= max) return items;
  const copy = items.slice();
  for (let i = 0; i < max; i++) {
    const j = i + Math.floor(Math.random() * (copy.length - i));
    const tmp = copy[i] as T;
    copy[i] = copy[j] as T;
    copy[j] = tmp;
  }
  return copy.slice(0, max);
}
