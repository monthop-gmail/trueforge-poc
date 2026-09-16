import { createPublicKey, verify as verifySignature, type KeyObject } from "node:crypto";

/**
 * Verifies RS256 tokens against a remote JWKS.
 *
 * The keyset this is aimed at is large — the gateway's tenant-wide JWKS is
 * several megabytes — so keys are cached individually by `kid` and a miss
 * triggers at most one refetch per `refreshCooldownMs`. Without that cooldown a
 * burst of tokens carrying an unknown kid would pull the whole keyset per
 * request.
 */
export interface JwksVerifierOptions {
  jwksUrl: string;
  issuer: string;
  /** Rejected unless the token's `aud` contains one of these. Empty disables the check. */
  audiences: string[];
  /** Clock skew allowed on exp/nbf, in seconds. */
  clockSkewSec?: number;
  refreshCooldownMs?: number;
  fetchImpl?: typeof fetch;
}

export interface VerifiedToken {
  subject: string;
  claims: Record<string, unknown>;
}

/**
 * The keyset could not be read. Separate from JwtVerificationError on purpose:
 * this is our outage, and answering it as a rejected credential would tell the
 * caller their token went bad.
 */
export class JwksUnavailableError extends Error {
  constructor(
    message: string,
    readonly reason: string,
  ) {
    super(message);
    this.name = "JwksUnavailableError";
  }
}

export class JwtVerificationError extends Error {
  constructor(
    message: string,
    readonly reason: string,
  ) {
    super(message);
    this.name = "JwtVerificationError";
  }
}

interface JwtHeader {
  alg?: string;
  kid?: string;
  typ?: string;
}

function decodeSegment(segment: string): Record<string, unknown> {
  const json = Buffer.from(segment, "base64url").toString("utf8");
  const parsed: unknown = JSON.parse(json);
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new JwtVerificationError("JWT segment is not an object", "malformed");
  }
  return parsed as Record<string, unknown>;
}

function asStringArray(value: unknown): string[] {
  if (typeof value === "string") return [value];
  if (Array.isArray(value)) return value.filter((entry): entry is string => typeof entry === "string");
  return [];
}

export class JwksVerifier {
  readonly #options: Required<Omit<JwksVerifierOptions, "fetchImpl">> & { fetchImpl: typeof fetch };
  readonly #keys = new Map<string, KeyObject>();
  #lastRefresh = 0;

  constructor(options: JwksVerifierOptions) {
    this.#options = {
      clockSkewSec: 60,
      refreshCooldownMs: 60_000,
      fetchImpl: fetch,
      ...options,
    };
  }

  async verify(token: string, now = Date.now()): Promise<VerifiedToken> {
    const parts = token.split(".");
    if (parts.length !== 3) {
      throw new JwtVerificationError("JWT must have three segments", "malformed");
    }
    const [headerSeg, payloadSeg, signatureSeg] = parts as [string, string, string];

    const header = decodeSegment(headerSeg) as JwtHeader;
    if (header.alg !== "RS256") {
      throw new JwtVerificationError(`Unsupported alg ${String(header.alg)}`, "unsupported_alg");
    }
    if (!header.kid) {
      throw new JwtVerificationError("JWT header has no kid", "no_kid");
    }

    const key = await this.#resolveKey(header.kid, now);
    const signed = Buffer.from(`${headerSeg}.${payloadSeg}`, "utf8");
    const signature = Buffer.from(signatureSeg, "base64url");
    if (!verifySignature("RSA-SHA256", signed, key, signature)) {
      throw new JwtVerificationError("Signature does not verify", "bad_signature");
    }

    const claims = decodeSegment(payloadSeg);
    const nowSec = Math.floor(now / 1000);
    const skew = this.#options.clockSkewSec;

    if (typeof claims.exp === "number" && claims.exp + skew < nowSec) {
      throw new JwtVerificationError("Token expired", "expired");
    }
    if (typeof claims.nbf === "number" && claims.nbf - skew > nowSec) {
      throw new JwtVerificationError("Token not yet valid", "not_yet_valid");
    }
    if (claims.iss !== this.#options.issuer) {
      throw new JwtVerificationError(`Unexpected issuer ${String(claims.iss)}`, "bad_issuer");
    }
    if (this.#options.audiences.length > 0) {
      const audience = asStringArray(claims.aud);
      const matched = audience.some((entry) => this.#options.audiences.includes(entry));
      if (!matched) {
        // Without this check a token minted for any other resource in the same
        // tenant would be accepted here.
        throw new JwtVerificationError("Token audience does not include this resource", "bad_audience");
      }
    }

    const subject =
      (typeof claims.email === "string" && claims.email) ||
      (typeof claims.sub === "string" && claims.sub) ||
      "";
    if (!subject) {
      throw new JwtVerificationError("Token carries no sub or email", "no_subject");
    }
    return { subject, claims };
  }

  async #resolveKey(kid: string, now: number): Promise<KeyObject> {
    const cached = this.#keys.get(kid);
    if (cached) return cached;
    if (now - this.#lastRefresh < this.#options.refreshCooldownMs) {
      throw new JwtVerificationError(`Unknown kid ${kid}`, "unknown_kid");
    }
    await this.#refresh(now);
    const refreshed = this.#keys.get(kid);
    if (!refreshed) {
      throw new JwtVerificationError(`Unknown kid ${kid}`, "unknown_kid");
    }
    return refreshed;
  }

  async #refresh(now: number): Promise<void> {
    this.#lastRefresh = now;
    let response: Response;
    try {
      response = await this.#options.fetchImpl(this.#options.jwksUrl, {
        headers: { accept: "application/json" },
      });
    } catch (error) {
      throw new JwksUnavailableError(
        `JWKS fetch failed: ${error instanceof Error ? error.message : String(error)}`,
        "jwks_unreachable",
      );
    }
    if (!response.ok) {
      throw new JwksUnavailableError(`JWKS fetch failed with HTTP ${response.status}`, "jwks_http_error");
    }
    const body = (await response.json()) as { keys?: unknown };
    if (!Array.isArray(body.keys)) {
      throw new JwksUnavailableError("JWKS has no keys array", "jwks_malformed");
    }
    for (const entry of body.keys) {
      if (typeof entry !== "object" || entry === null) continue;
      const jwk = entry as Record<string, unknown>;
      if (jwk.kty !== "RSA" || typeof jwk.kid !== "string") continue;
      if (typeof jwk.alg === "string" && jwk.alg !== "RS256") continue;
      try {
        this.#keys.set(jwk.kid, createPublicKey({ key: jwk as never, format: "jwk" }));
      } catch {
        // One malformed key must not cost us the rest of the keyset.
      }
    }
  }

  /** Cached key count — exposed for the smoke test and for health output. */
  get cachedKeyCount(): number {
    return this.#keys.size;
  }

  /**
   * Ends the refresh cooldown now. Only the smoke test uses this: real rotation
   * is handled by the cooldown expiring on its own.
   */
  forceRefreshWindow(): void {
    this.#lastRefresh = 0;
  }
}
