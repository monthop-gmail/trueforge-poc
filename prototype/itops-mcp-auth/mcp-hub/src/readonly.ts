import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";

/**
 * Tools the read-only route may run. Deny-by-default: anything not listed here
 * is still registered, but its handler refuses. Registering the refusal instead
 * of hiding the tool is deliberate — a caller that names a mutating tool gets an
 * explicit "not allowed here", which is auditable, rather than "unknown tool",
 * which is indistinguishable from a typo.
 */
export const IT_READ_ONLY_TOOLS: readonly string[] = [
  "zabbix_get_active_problems",
  "zabbix_get_device_status",
  "zabbix_get_metrics",
  "meshcentral_get_inventory",
  "zktime_get_status",
  "zktime_inspect_schema",
  "zktime_list_employees",
  "zktime_list_punches",
  "zktime_list_departments",
  "zktime_list_devices",
  "pstack_get_status",
  "pstack_list_tools",
  "rag_get_status",
  "rag_list_sources",
  "rag_search",
  "rag_get_chunk",
  "rag_ocr_status",
  "rag_list_ocr_queue",
  "rag_get_ocr_page",
];

export const ACCOUNTING_READ_ONLY_TOOLS: readonly string[] = [
  "express_get_status",
  "express_list_customers",
  "express_list_vendors",
  "express_list_items",
  "express_list_gl_accounts",
  "express_list_ar_invoices",
  "allinone_get_status",
  "allinone_list_customers",
  "allinone_list_vendors",
  "allinone_list_items",
  "allinone_list_gl_accounts",
  "allinone_list_ar_invoices",
  "odoo_get_status",
  "odoo_search_read",
  "odoo_read",
  "odoo_fields_get",
  "rag_get_status",
  "rag_list_sources",
  "rag_search",
  "rag_get_chunk",
  "rag_ocr_status",
  "rag_list_ocr_queue",
  "rag_get_ocr_page",
];

/**
 * Wraps the server so every `tool()` registration passes through an allowlist.
 *
 * A denied tool is registered and then disabled, which buys two things at once:
 * the SDK filters disabled tools out of `tools/list`, so an agent is not tempted
 * to call something it cannot use, and a direct `tools/call` still answers
 * `Tool <name> disabled` — a refusal that names the tool, not the `unknown tool`
 * you would get by never registering it.
 *
 * A Proxy keeps this to one place instead of threading a flag through all 52
 * registration sites, and it cannot be bypassed by adding a tool later — a new
 * tool is denied until someone puts it on the list.
 */
export function withReadOnlyGuard(server: McpServer, allow: readonly string[]): McpServer {
  const allowed = new Set(allow);
  return new Proxy(server, {
    get(target, prop, receiver) {
      const value = Reflect.get(target, prop, receiver);
      if (prop !== "tool" || typeof value !== "function") {
        return typeof value === "function" ? value.bind(target) : value;
      }
      return (name: string, ...rest: unknown[]) => {
        const registered = (value as (...a: unknown[]) => { disable?: () => void }).call(
          target,
          name,
          ...rest,
        );
        if (!allowed.has(name)) registered?.disable?.();
        return registered;
      };
    },
  });
}

/** Parses `HUB_READ_ONLY_TOOLS`; empty means use the built-in list for the role. */
export function parseToolOverride(raw: string): string[] | undefined {
  const names = raw
    .split(",")
    .map((entry) => entry.trim())
    .filter(Boolean);
  return names.length > 0 ? names : undefined;
}
