import { log, optionalEnv, requireEnv } from "@itops/mcp-common";
import { createAuthApp, type HubRole } from "./app.js";
import { JwksVerifier } from "./jwks.js";

function parsePrincipalRoles(raw: string): Record<string, HubRole> {
  if (!raw.trim()) return {};
  const parsed: unknown = JSON.parse(raw);
  if (typeof parsed !== "object" || parsed === null || Array.isArray(parsed)) {
    throw new Error("AUTH_JWT_PRINCIPAL_ROLES must be a JSON object of principal → role");
  }
  const out: Record<string, HubRole> = {};
  for (const [principal, role] of Object.entries(parsed)) {
    if (role !== "it" && role !== "admin" && role !== "accounting") {
      throw new Error(`AUTH_JWT_PRINCIPAL_ROLES: ${principal} has invalid role ${String(role)}`);
    }
    out[principal] = role;
  }
  return out;
}

function parseDefaultRole(raw: string): HubRole | undefined {
  if (!raw) return undefined;
  if (raw !== "it" && raw !== "admin" && raw !== "accounting") {
    throw new Error(`AUTH_JWT_DEFAULT_ROLE must be it, admin or accounting, got ${raw}`);
  }
  return raw;
}

const jwksUrl = optionalEnv("AUTH_JWT_JWKS_URL", "");
const issuer = optionalEnv("AUTH_JWT_ISSUER", "");
if (Boolean(jwksUrl) !== Boolean(issuer)) {
  throw new Error("AUTH_JWT_JWKS_URL and AUTH_JWT_ISSUER must be set together");
}

const audiences = optionalEnv("AUTH_JWT_AUDIENCES", "")
  .split(",")
  .map((entry) => entry.trim())
  .filter(Boolean);

const app = createAuthApp({
  staticTokens: {
    it: requireEnv("IT_TOKEN"),
    admin: requireEnv("ADMIN_TOKEN"),
    accounting: requireEnv("ACCOUNTING_TOKEN"),
  },
  verifier: jwksUrl
    ? new JwksVerifier({
        jwksUrl,
        issuer,
        audiences,
        clockSkewSec: Number(optionalEnv("AUTH_JWT_CLOCK_SKEW_SEC", "60")),
        refreshCooldownMs: Number(optionalEnv("AUTH_JWT_REFRESH_COOLDOWN_MS", "60000")),
      })
    : undefined,
  principalRoles: parsePrincipalRoles(optionalEnv("AUTH_JWT_PRINCIPAL_ROLES", "")),
  defaultRole: parseDefaultRole(optionalEnv("AUTH_JWT_DEFAULT_ROLE", "")),
});

const port = Number(optionalEnv("PORT", "3000"));
app.listen(port, "0.0.0.0", () => {
  log("info", "MCP auth server listening", { port, jwt: jwksUrl ? "enabled" : "disabled" });
});
