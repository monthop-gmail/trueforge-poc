# Dual MCP PoC — topology, version และเจ้าของ credential

ทีม `monthop-gmail/trueforge` · รอบ 1 (เส้นทางตรง) และรอบ 2 (gateway) ทั้งคู่วันที่ 16 ก.ย. 2026
แผนที่ยึด: `plan-5584d6e3-f822-4cc4-8921-1c594c77b9f2` · กระทู้ `dis-bc779b20-aa97-421c-ba49-4623abe8123e`

## 1. สอง topology ที่ทดสอบไปแล้วทั้งคู่

```
A — ทางตรง
   ผู้ใช้ ─┬─ curl / MCP client ───────────────┐
          └─ TrueForge harness (รันในเครื่อง) ─┤
                                               ├─→ Collaboration MCP (Cloudflare Worker)  /mcp
                                               └─→ IT Ops Nginx (จุดบังคับ RBAC)          /mcp/it/mcp
                                                      └─→ mcp-hub-it → sub-mcp-* (fixture)

B — ผ่าน gateway
   client ─→ TrueFoundry AI Gateway ─→ (credential ขาออกของแต่ละ connector) ─┬─→ Collaboration MCP
             ขาเข้า: TrueFoundry PAT                                         └─→ IT Ops hub ของไซต์
             https://gateway.truefoundry.ai/<tenant>/mcp/<connector>/server
```

topology B ไม่ใช่ของที่ติดมากับ TrueForge ตัว harness ฝั่ง OSS มองมันเป็น **manifest คนละชนิด** —
`MCPServerManifest` เป็น `oneOf` ระหว่าง `remote` กับ `truefoundry` และตัว `truefoundry` มี `url`
เป็น *"Resolved AI Gateway proxy URL"* ที่ control plane เป็นคนออกให้
(`listGatewayInstallations` → `resolveDefaultGatewayUrl` ใน `packages/trueforge/src/truefoundry/`)

รอบ 2 ยิงผ่าน gateway ตรง ๆ ไม่ได้ผ่าน harness ดังนั้น **"gateway ใช้ได้" กับ "harness ใช้ได้"
เป็นผลคนละใบใน `dual-mcp-results.md` ไม่ใช่ใบเดียวกัน**

## 2. ตาราง version (ของที่รันจริง)

| ส่วนประกอบ | ที่ปักหมุด | รันอย่างไร |
| --- | --- | --- |
| TrueFoundry AI Gateway | installation `gateway-default` → `https://gateway.truefoundry.ai`, tenant `<tenant>` | SaaS แผน **Developer (ฟรี)** · control plane `https://<tenant>.truefoundry.cloud` |
| TrueForge harness | `@truefoundry/trueforge` **0.1.4** (npx, standalone/SQLite) | `localhost:8790`, `PUBLIC_BASE_URL=http://localhost:8790` |
| TrueForge source (ใช้ตรวจข้อความเรื่อง auth) | `truefoundry/trueforge` @ `ffcd60d8949c55527319fa912eeb0f11fb7e0475` (2026-09-16) | ไม่ได้ build |
| IT Ops hub — sandbox | `monthop-gmail/itops-mcp-hub` @ `da63143431b1929f4e9ca2743263821faa3ee88d` | compose project `itops-poc`, `127.0.0.1:19080` |
| IT Ops hub — ไซต์ `<site>` | ทีมไซต์เป็นคน deploy, `https://<itops-site-host>` | เข้าถึงผ่าน gateway เท่านั้น บทบาท IT อ่านอย่างเดียว |
| Collaboration MCP | Worker ที่ deploy อยู่, `serverInfo` `ai-collaboration` **0.1.0** | deployment ที่ใช้ร่วมกัน (ดู §4) |
| Collaboration MCP source | `monthop-gmail/ai-collaboration-mcp` @ `55fdc5944cc4a0338bd771fd829f5a41a1f5765c` | ใช้อ้างอิงเท่านั้น |
| MCP protocol | `2025-06-18` ตกลงกันได้ทุกเส้นทาง | — |
| เครื่องที่รัน | Node v22.22.2, Docker Compose v5.0.2 | — |

**ช่องโหว่ของการปักหมุดที่ต้องบอกให้ครบ:** build ของ Worker ที่ deploy อยู่ ปักหมุดจากภายนอกไม่ได้ —
`serverInfo.version` เป็น `0.1.0` ที่เขียนมือ ไม่ใช่ commit ดังนั้น SHA ข้างบนคือสิ่งที่เรา *อ่าน*
ไม่ใช่สิ่งที่พิสูจน์ได้ว่า Worker *รัน* · ฮับของไซต์ก็เช่นกัน ปักหมุดได้เท่าที่ทีมไซต์รายงานมา

## 3. sandbox รันอะไร และไม่รันอะไร

ยกขึ้นจาก repo ของฮับด้วย `--no-deps` จึงมีแต่ครึ่งที่เป็น MCP: `nginx`, `mcp-oauth`, `mcp-hub-it`,
`mcp-hub-admin` และ sub-server อ่านอย่างเดียวอีก 5 ตัว (`zabbix`, `meshcentral`, `rag`, `zktime`,
`pstack`) ทุกตัวอยู่บน backend **fixture** — ไม่มี Zabbix จริง ไม่มี MeshCentral ไม่มีฮับบัญชี
ไม่มี tunnel ไม่มีข้อมูลไซต์ · พอร์ตเลื่อนออกจากค่าเริ่มต้นของฮับทั้งชุด (`19080`, `19443`, `19051`,
`19444`, `14433`) เพื่อไม่ให้ชนกับ deployment จริงที่อาจรันบนเครื่องเดียวกัน

sandbox ยังเป็นที่ที่ทางตันของ gateway OAuth ทั้งสองแบบถูกจำลองซ้ำด้วยโค้ด upstream ที่ไม่แก้อะไร
จึงไม่ต้องเอาไซต์จริงไปทดลองเพื่อยืนยันข้อค้นพบ 6

## 4. ใครเป็นเจ้าของ credential ไหน

| credential | ใครออกให้ | ใครถือ | ขอบเขตความเสียหายถ้าหลุด |
| --- | --- | --- | --- |
| `IT_TOKEN` / `ADMIN_TOKEN` / `ACCOUNTING_TOKEN` ของ sandbox | สร้างใหม่เฉพาะ sandbox | `.env` ของ sandbox, gitignore ไว้ | แค่ sandbox — ไม่มีการคัดลอกโทเคนของไซต์เข้ามา |
| `IT_TOKEN` ของไซต์ | deployment ของไซต์ | เจ้าของงานเป็นคนกรอกลง `.env.tfy` (gitignore, `0600`) และเก็บไว้ที่ connector บน gateway | บทบาท IT อ่านอย่างเดียวของหนึ่งไซต์ · เป็นความลับที่ใช้ร่วมกันและเพิกถอนรายตัวไม่ได้ (ข้อค้นพบ 2) |
| Bearer แบบ static ของ collaboration | มีอยู่ก่อนแล้ว เจ้าของงานออกให้ | environment ของ session นี้ และ connector บน gateway | **workspace production ที่ใช้ร่วมกันทั้งหมด** |
| TrueFoundry PAT | เจ้าของงาน จาก tenant แผน Developer | `.env.tfy`, gitignore | ทั้ง tenant — ควร revoke เมื่อ PoC จบ |
| OAuth client ที่ลงทะเบียนกับฮับ | เกิดจาก DCR ระหว่างทดสอบ | `MemoryStore` ของฮับ หายเมื่อ restart | แค่ sandbox |
| secret ของ connector บน TrueForge | สำเนาของข้างบน | SQLite ใต้ `.local/` | ถูก redact ในทุก response ของ API |

สองใบในนี้ไม่ได้อยู่ใน sandbox — Bearer ของ collaboration กับ IT token ของไซต์ — และตอนนี้ทั้งคู่
ไปอยู่บน gateway ของบุคคลที่สามด้วย นั่นคือสิ่งที่ topology แบบ gateway แลกมา และเป็นเหตุผลที่
`dual-mcp-results.md` มีหมายเหตุเรื่องเส้นทางข้อมูลปิดท้าย

## 5. สิ่งที่ยังขาด

1. **principal ที่สองบน TrueFoundry** — ถ้าไม่มี *gateway authorization* ก็ยังทดสอบไม่ได้
   (ข้อค้นพบ 8) แผนฟรีให้ 3 users จึงเป็นการตัดสินใจ ไม่ใช่การจัดซื้อ
2. **deployment ทดสอบของ collaboration** — บล็อก OAuth ของ collab และการทดสอบเขียนทั้งหมด
3. **credential ของ model provider สำหรับ TrueForge** — harness ไม่มี API "เรียก tool ตัวนี้"
   การเรียกเกิดใน agent turn ซึ่งต้องมี model ส่วนการ discover ไม่ต้อง จึงพิสูจน์ได้เฉพาะ discovery
4. **คำตัดสินเรื่อง allowlist ของ redirect บนฮับ** — gateway OAuth ติดอยู่จนกว่าจะมีคำตอบ (ข้อค้นพบ 6)
