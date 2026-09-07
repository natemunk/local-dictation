const STREAM_TICKET_VERSION = 1 as const;
const STREAM_TICKET_PREFIX = "ld-ticket.";
const STREAM_TICKET_TTL_MS = 30_000;
const MINIMUM_STREAM_SECRET_CHARACTERS = 32;

export const STREAM_PATH = "/stream";
export const STREAM_TICKET_PATH = "/v1/stream-tickets";
export const STREAM_PROTOCOL = "local-dictation.v1";

const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export type StreamTicketMode = "clean" | "literal";

export type StreamTicketInput = Readonly<{
  requestId: string;
  mode: StreamTicketMode;
  allowsCloudFallback: boolean;
}>;

export type StreamTicketClaims = Readonly<{
  v: typeof STREAM_TICKET_VERSION;
  id: string;
  mode: StreamTicketMode;
  fallback: boolean;
  client: "pwa";
  iat: number;
  exp: number;
  nonce: string;
}>;

export type StreamTicketGrant = Readonly<{
  requestId: string;
  protocol: typeof STREAM_PROTOCOL;
  ticket: string;
  streamPath: typeof STREAM_PATH;
  expiresAt: number;
}>;

export type StreamTicketAuthority = Readonly<{
  issue: (input: StreamTicketInput) => Promise<StreamTicketGrant>;
  verifyProtocols: (protocolHeader: string | null) => Promise<StreamTicketClaims>;
}>;

export class StreamTicketError extends Error {
  constructor(readonly code: "misconfigured" | "invalid" | "expired") {
    super(code);
    this.name = "StreamTicketError";
  }
}

function encodeBase64URL(bytes: Uint8Array<ArrayBuffer>): string {
  let binary = "";
  for (const byte of bytes) binary += String.fromCharCode(byte);
  return btoa(binary).replaceAll("+", "-").replaceAll("/", "_").replace(/=+$/u, "");
}

function decodeBase64URL(value: string): Uint8Array<ArrayBuffer> {
  if (!/^[A-Za-z0-9_-]+$/u.test(value)) throw new StreamTicketError("invalid");
  const padded = value.replaceAll("-", "+").replaceAll("_", "/")
    + "=".repeat((4 - (value.length % 4)) % 4);
  let binary: string;
  try {
    binary = atob(padded);
  } catch {
    throw new StreamTicketError("invalid");
  }
  const bytes = new Uint8Array(new ArrayBuffer(binary.length));
  for (let index = 0; index < binary.length; index += 1) {
    bytes[index] = binary.charCodeAt(index);
  }
  return bytes;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function parseClaims(value: unknown): StreamTicketClaims {
  if (
    !isRecord(value)
    || value.v !== STREAM_TICKET_VERSION
    || typeof value.id !== "string"
    || !UUID_PATTERN.test(value.id)
    || (value.mode !== "clean" && value.mode !== "literal")
    || typeof value.fallback !== "boolean"
    || value.client !== "pwa"
    || typeof value.iat !== "number"
    || !Number.isSafeInteger(value.iat)
    || typeof value.exp !== "number"
    || !Number.isSafeInteger(value.exp)
    || typeof value.nonce !== "string"
    || !UUID_PATTERN.test(value.nonce)
  ) {
    throw new StreamTicketError("invalid");
  }
  return value as StreamTicketClaims;
}

async function importKey(secret: string): Promise<CryptoKey> {
  if (secret.length < MINIMUM_STREAM_SECRET_CHARACTERS) {
    throw new StreamTicketError("misconfigured");
  }
  return crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"],
  );
}

function ticketProtocol(protocolHeader: string | null): string {
  if (protocolHeader === null) throw new StreamTicketError("invalid");
  const protocols = protocolHeader.split(",").map((value) => value.trim());
  if (!protocols.includes(STREAM_PROTOCOL)) throw new StreamTicketError("invalid");
  const tickets = protocols.filter((value) => value.startsWith(STREAM_TICKET_PREFIX));
  if (tickets.length !== 1) throw new StreamTicketError("invalid");
  return tickets[0]!;
}

export function createStreamTicketAuthority(
  secret: string,
  now: () => number = () => Date.now(),
): StreamTicketAuthority {
  let keyPromise: Promise<CryptoKey> | null = null;
  const key = () => {
    keyPromise ??= importKey(secret);
    return keyPromise;
  };

  return {
    async issue(input) {
      const requestId = input.requestId.toLowerCase();
      if (!UUID_PATTERN.test(requestId)) throw new StreamTicketError("invalid");
      const issuedAt = now();
      const claims: StreamTicketClaims = {
        v: STREAM_TICKET_VERSION,
        id: requestId,
        mode: input.mode,
        fallback: input.allowsCloudFallback,
        client: "pwa",
        iat: issuedAt,
        exp: issuedAt + STREAM_TICKET_TTL_MS,
        nonce: crypto.randomUUID().toLowerCase(),
      };
      const payload = new TextEncoder().encode(JSON.stringify(claims));
      const signature = new Uint8Array(await crypto.subtle.sign("HMAC", await key(), payload));
      return {
        requestId,
        protocol: STREAM_PROTOCOL,
        ticket: `${STREAM_TICKET_PREFIX}${encodeBase64URL(payload)}.${encodeBase64URL(signature)}`,
        streamPath: STREAM_PATH,
        expiresAt: claims.exp,
      };
    },

    async verifyProtocols(protocolHeader) {
      const protocol = ticketProtocol(protocolHeader);
      const encoded = protocol.slice(STREAM_TICKET_PREFIX.length);
      const parts = encoded.split(".");
      if (parts.length !== 2) throw new StreamTicketError("invalid");
      const payload = decodeBase64URL(parts[0]!);
      const signature = decodeBase64URL(parts[1]!);
      const valid = await crypto.subtle.verify("HMAC", await key(), signature, payload);
      if (!valid) throw new StreamTicketError("invalid");

      let decoded: unknown;
      try {
        decoded = JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(payload));
      } catch {
        throw new StreamTicketError("invalid");
      }
      const claims = parseClaims(decoded);
      const current = now();
      if (claims.exp <= current || claims.iat > current + 5_000 || claims.exp - claims.iat > STREAM_TICKET_TTL_MS) {
        throw new StreamTicketError("expired");
      }
      return claims;
    },
  };
}
