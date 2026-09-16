import { createSign, generateKeyPairSync, type KeyObject } from "node:crypto";
import { createAuthApp } from "./app.js";
import { JwksVerifier } from "./jwks.js";

const IT = "it-token-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
const ADMIN = "admin-token-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
const ACCOUNTING = "acct-token-cccccccccccccccccccccccccccccc";
const ISSUER = "https://gateway.example.test/oauth2/tenant/itops";
const AUDIENCE = "https://gateway.example.test/tenant/mcp/itops/server";
const KID = "smoke-key-1";

// A local keypair stands in for the gateway's signing key, so the whole chain is
// exercised without reaching any network.
const { privateKey, publicKey } = generateKeyPairSync("rsa", { modulusLength: 2048 });
const jwk = { ...(publicKey.export({ format: "jwk" }) as Record<string, unknown>), kid: KID, alg: "RS256", use: "sig" };

function sign(claims: Record<string, unknown>, kid = KID): string {
  const header = Buffer.from(JSON.stringify({ alg: "RS256", typ: "JWT", kid })).toString("base64url");
  const payload = Buffer.from(JSON.stringify(claims)).toString("base64url");
  const signer = createSign("RSA-SHA256");
  signer.update(`${header}.${payload}`);
  return `${header}.${payload}.${signer.sign(privateKey).toString("base64url")}`;
}

function signWith(key: KeyObject, payloadClaims: Record<string, unknown>, kid: string): string {
  const header = Buffer.from(JSON.stringify({ alg: "RS256", typ: "JWT", kid })).toString("base64url");
  const payload = Buffer.from(JSON.stringify(payloadClaims)).toString("base64url");
  const signer = createSign("RSA-SHA256");
  signer.update(`${header}.${payload}`);
  return `${header}.${payload}.${signer.sign(key).toString("base64url")}`;
}

function claims(extra: Record<string, unknown> = {}): Record<string, unknown> {
  const now = Math.floor(Date.now() / 1000);
  return { iss: ISSUER, aud: AUDIENCE, sub: "user-1", email: "alice@example.test", iat: now, exp: now + 300, ...extra };
}

let jwksFetches = 0;
let jwksKeys = [jwk];
let jwksDown = false;
const fetchImpl = (async () => {
  jwksFetches += 1;
  if (jwksDown) {
    return new Response("upstream down", { status: 503 });
  }
  return new Response(JSON.stringify({ keys: jwksKeys }), { headers: { "content-type": "application/json" } });
}) as unknown as typeof fetch;

async function main(): Promise<void> {
  const verifier = new JwksVerifier({
    jwksUrl: "https://jwks.example.test/keys",
    issuer: ISSUER,
    audiences: [AUDIENCE],
    refreshCooldownMs: 60_000,
    fetchImpl,
  });

  const app = createAuthApp({
    staticTokens: { it: IT, admin: ADMIN, accounting: ACCOUNTING },
    verifier,
    principalRoles: { "alice@example.test": "it", "bob@example.test": "admin" },
  });

  const server = app.listen(0, "127.0.0.1");
  await new Promise<void>((resolve) => server.once("listening", resolve));
  const addr = server.address();
  if (!addr || typeof addr === "string") throw new Error("listen failed");
  const base = `http://127.0.0.1:${addr.port}`;

  const check = async (
    label: string,
    role: string,
    token: string | undefined,
    expected: number,
    expectedActor?: string,
  ): Promise<void> => {
    const res = await fetch(`${base}/verify/${role}`, {
      headers: token ? { authorization: `Bearer ${token}` } : {},
    });
    if (res.status !== expected) {
      throw new Error(`${label}: expected ${expected}, got ${res.status}`);
    }
    if (expectedActor !== undefined && res.headers.get("x-actor") !== expectedActor) {
      throw new Error(`${label}: expected actor ${expectedActor}, got ${res.headers.get("x-actor")}`);
    }
    console.log(`ok   ${label} -> ${res.status}${expectedActor ? ` actor=${expectedActor}` : ""}`);
  };

  // The static path must keep behaving exactly as the Nginx token map did.
  await check("no credential", "it", undefined, 401);
  await check("unknown token", "it", "not-a-real-token", 401);
  await check("static IT on it", "it", IT, 200, "token:it");
  await check("static IT on admin", "admin", IT, 403);
  await check("static admin on admin", "admin", ADMIN, 200, "token:admin");
  // The map this replaces let admin through on the IT path; keep that.
  await check("static admin on it", "it", ADMIN, 200, "token:admin");
  await check("static accounting on it", "it", ACCOUNTING, 403);

  // The JWT path carries the caller's own identity instead of a shared one.
  await check("jwt alice on it", "it", sign(claims()), 200, "alice@example.test");
  await check("jwt alice on admin", "admin", sign(claims()), 403);
  await check("jwt bob on admin", "admin", sign(claims({ sub: "user-2", email: "bob@example.test" })), 200, "bob@example.test");
  await check("jwt bob on it", "it", sign(claims({ sub: "user-2", email: "bob@example.test" })), 200, "bob@example.test");
  await check("jwt unlisted principal", "it", sign(claims({ sub: "user-3", email: "carol@example.test" })), 403);

  await check("jwt expired", "it", sign(claims({ exp: Math.floor(Date.now() / 1000) - 3600 })), 401);
  await check("jwt wrong issuer", "it", sign(claims({ iss: "https://evil.example.test" })), 401);
  await check("jwt wrong audience", "it", sign(claims({ aud: "https://other.example.test/server" })), 401);
  await check("jwt unknown kid", "it", sign(claims(), "no-such-kid"), 401);

  const tampered = sign(claims()).split(".");
  tampered[1] = Buffer.from(JSON.stringify(claims({ email: "mallory@example.test" }))).toString("base64url");
  await check("jwt tampered payload", "it", tampered.join("."), 401);

  // The keyset is megabytes in production; a miss must not refetch per request.
  if (jwksFetches > 2) {
    throw new Error(`JWKS refetched ${jwksFetches} times; the cooldown is not holding`);
  }
  console.log(`ok   jwks fetched ${jwksFetches} time(s) across the checks above`);

  // --- cooldown ------------------------------------------------------------
  // Several tokens carrying an unknown kid must not pull the keyset once each.
  const before = jwksFetches;
  for (let i = 0; i < 5; i += 1) {
    await check(`cooldown burst ${i + 1}`, "it", sign(claims(), `missing-kid-${i}`), 401);
  }
  if (jwksFetches !== before) {
    throw new Error(`cooldown broken: ${jwksFetches - before} extra fetches for 5 unknown-kid tokens`);
  }
  console.log(`ok   cooldown held: 5 unknown-kid tokens caused 0 extra JWKS fetches`);

  // --- rotation ------------------------------------------------------------
  // A key added after the cooldown window must be picked up on the next miss,
  // and tokens signed by the old key must keep working.
  const rotated = generateKeyPairSync("rsa", { modulusLength: 2048 });
  const ROTATED_KID = "smoke-key-2";
  const rotatedJwk = { ...(rotated.publicKey.export({ format: "jwk" }) as Record<string, unknown>), kid: ROTATED_KID, alg: "RS256", use: "sig" };
  jwksKeys = [jwk, rotatedJwk];
  await check("rotation: new kid before refresh window", "it", signWith(rotated.privateKey, claims(), ROTATED_KID), 401);
  verifier.forceRefreshWindow();
  await check("rotation: new kid after refresh window", "it", signWith(rotated.privateKey, claims(), ROTATED_KID), 200, "alice@example.test");
  await check("rotation: old kid still valid", "it", sign(claims()), 200, "alice@example.test");
  console.log("ok   rotation picked up the new key without dropping the old one");

  // --- outage --------------------------------------------------------------
  // A JWKS that cannot be fetched is our outage, not a bad credential: 503, so a
  // caller is not told their token went wrong, and static callers are untouched.
  jwksDown = true;
  verifier.forceRefreshWindow();
  await check("outage: unknown kid while JWKS is down", "it", sign(claims(), "kid-during-outage"), 503);
  await check("outage: cached key still verifies", "it", sign(claims()), 200, "alice@example.test");
  await check("outage: static credential unaffected", "it", IT, 200, "token:it");
  jwksDown = false;
  console.log("ok   JWKS outage answered 503 and left cached and static callers working");

  server.close();
  console.log("auth smoke ok");
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
