import express, { type Request, type Response } from "express";
import { log } from "@itops/mcp-common";
import { JwksUnavailableError, JwksVerifier, JwtVerificationError } from "./jwks.js";

export type HubRole = "it" | "admin" | "accounting";

export interface AuthConfig {
  /** Static role tokens kept so existing clients keep working during a migration. */
  staticTokens: Partial<Record<HubRole, string>>;
  verifier?: JwksVerifier;
  /** Verified principal → role. The gateway proves who; this hub decides what. */
  principalRoles: Record<string, HubRole>;
  /** Role for a verified principal that is not listed above. Undefined means deny. */
  defaultRole?: HubRole;
}

const ROLES: HubRole[] = ["it", "admin", "accounting"];

/**
 * Which roles may use which path. Mirrors the Nginx token map this replaces:
 * admin was always allowed on the IT path, accounting never was.
 */
const ALLOWED_ROLES: Record<HubRole, HubRole[]> = {
  it: ["it", "admin"],
  admin: ["admin"],
  accounting: ["accounting"],
};

function bearer(req: Request): string {
  const header = req.get("authorization") ?? "";
  const match = /^Bearer\s+(.+)$/i.exec(header.trim());
  return match?.[1]?.trim() ?? "";
}

function staticRole(config: AuthConfig, token: string): HubRole | undefined {
  if (!token) return undefined;
  for (const role of ROLES) {
    const expected = config.staticTokens[role];
    if (expected && expected === token) return role;
  }
  return undefined;
}

/**
 * Nginx calls `/verify/<role>` through `auth_request`, so the only things that
 * matter here are the status code and the `X-Actor*` headers it copies onward.
 * 401 means "no usable credential", 403 means "this credential is not for this
 * path" — the same split the static token map produced before.
 */
export function createAuthApp(config: AuthConfig): express.Express {
  const app = express();
  app.disable("x-powered-by");
  app.set("trust proxy", true);

  app.get("/healthz", (_req, res) => {
    res.status(200).json({
      ok: true,
      service: "mcp-auth",
      jwt: config.verifier ? "enabled" : "disabled",
      cached_keys: config.verifier?.cachedKeyCount ?? 0,
    });
  });

  app.get("/verify/:role", (req: Request, res: Response) => {
    void handleVerify(config, req, res);
  });

  return app;
}

async function handleVerify(config: AuthConfig, req: Request, res: Response): Promise<void> {
  const requested = req.params.role as HubRole;
  if (!ROLES.includes(requested)) {
    res.status(400).json({ error: "invalid_request", message: "Unknown role" });
    return;
  }

  const token = bearer(req);
  if (!token) {
    res.status(401).end();
    return;
  }

  const fromStatic = staticRole(config, token);
  if (fromStatic) {
    if (!ALLOWED_ROLES[requested].includes(fromStatic)) {
      log("warn", "auth denied: static role cannot use this path", { role: fromStatic, requested });
      res.setHeader("X-Actor", `token:${fromStatic}`);
      res.setHeader("X-Actor-Source", "static-denied");
      res.status(403).end();
      return;
    }
    res.setHeader("X-Actor", `token:${fromStatic}`);
    res.setHeader("X-Actor-Source", "static");
    res.setHeader("X-Actor-Role", fromStatic);
    res.status(200).end();
    return;
  }

  if (!config.verifier) {
    res.status(401).end();
    return;
  }

  try {
    const verified = await config.verifier.verify(token);
    const role = config.principalRoles[verified.subject] ?? config.defaultRole;
    if (!role) {
      log("warn", "auth denied: verified principal has no role", { subject: verified.subject });
      res.setHeader("X-Actor", verified.subject);
      res.setHeader("X-Actor-Source", "jwt-denied");
      res.status(403).end();
      return;
    }
    if (!ALLOWED_ROLES[requested].includes(role)) {
      log("warn", "auth denied: role mismatch", { subject: verified.subject, role, requested });
      res.setHeader("X-Actor", verified.subject);
      res.setHeader("X-Actor-Source", "jwt-denied");
      res.setHeader("X-Actor-Role", role);
      res.status(403).end();
      return;
    }
    // Downstream hubs read this to record who actually asked, instead of
    // recording one shared service identity for everybody.
    res.setHeader("X-Actor", verified.subject);
    res.setHeader("X-Actor-Source", "jwt");
    res.setHeader("X-Actor-Role", role);
    res.status(200).end();
  } catch (error) {
    // An unreachable keyset is an outage on our side, not a failed credential;
    // answering 401 here would look like the caller's token went bad.
    if (error instanceof JwksUnavailableError) {
      log("error", "auth unavailable: keyset could not be read", { reason: error.reason });
      res.status(503).end();
      return;
    }
    if (error instanceof JwtVerificationError) {
      log("warn", "auth denied: token rejected", { reason: error.reason });
      res.status(401).end();
      return;
    }
    log("error", "auth verifier failed", { message: error instanceof Error ? error.message : String(error) });
    res.status(503).end();
  }
}
