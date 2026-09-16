# prototype: `mcp-auth` — ตัวตนรายคนที่ขอบของ itops-mcp-hub

ข้อเสนอสำหรับ `monthop-gmail/itops-mcp-hub` (ฐานที่ใช้ทดลอง: `da63143`) — **ยังไม่ได้เปิด PR
และยังไม่ได้ deploy ที่ไซต์ไหน** ทั้งหมดในนี้ทดสอบบน sandbox ท้องถิ่นเท่านั้น

## โจทย์

วันนี้ทั้ง gateway และฮับรู้แค่ว่า "โทเคนใบนี้ถูก" แต่ไม่รู้ว่า *ใคร* เป็นคนสั่ง — Nginx เทียบ
`Authorization` กับโทเคนสามใบแล้วได้ role กลับมา คนสิบคนที่ถือโทเคนใบเดียวกันจึงแยกกันไม่ออก
ทั้งใน log และใน audit (ข้อค้นพบ 1, 2 และ 8 ใน `docs/poc/dual-mcp-results.md`)

ถ้า gateway ส่ง **JWT ของผู้เรียก** ต่อมาให้ฮับ (โหมด `passthrough`) ฮับก็ตรวจลายเซ็นเองได้จาก
JWKS สาธารณะ แล้วได้ตัวตนจริงมาใช้ — โดยไม่ต้องถาม gateway ทุก request

**gateway พิสูจน์ว่าใคร · ฮับตัดสินว่าทำอะไรได้** การ map principal → role อยู่ที่ฮับ เพราะ RBAC
เป็นของฮับมาแต่เดิม

## สิ่งที่เพิ่ม

`packages/mcp-auth` — express ตัวเล็กที่ตอบ `auth_request` ของ Nginx

- `GET /verify/:role` → `200` พร้อม `X-Actor`, `X-Actor-Source`, `X-Actor-Role` · `401` เมื่อไม่มี
  หรือตรวจโทเคนไม่ผ่าน · `403` เมื่อตัวตนถูกต้องแต่ไม่มีสิทธิ์บน path นั้น · `503` เมื่อ JWKS ล่ม
  (ไม่ตอบ 401 เพราะนั่นจะทำให้ปัญหาฝั่งเราดูเหมือนโทเคนของผู้ใช้เสีย)
- ตรวจ RS256 ด้วย `node:crypto` ล้วน ไม่เพิ่ม dependency ใหม่
- **cache key ราย `kid`** และจำกัดการดึง JWKS ซ้ำด้วย cooldown — JWKS ของ gateway ที่วัดได้จริงคือ
  **6.4 MB / 4,024 keys** การดึงทั้งชุดต่อ request คือการฆ่าตัวตาย
- ตรวจ `iss`, `exp`/`nbf` (มี clock skew) และ **`aud`** — ถ้าไม่ตรวจ `aud` โทเคนที่ออกให้ระบบอื่น
  ใน tenant เดียวกันจะใช้ข้ามมาได้
- โทเคน static เดิมยังใช้ได้เหมือนเดิม จึงย้ายทีละ client ได้ ไม่ต้องตัดทั้งไซต์พร้อมกัน

`wiring.diff` — ส่วนที่ต่อเข้ากับของเดิม

- `/_auth_it|admin|accounting` เปลี่ยนจากการอ่าน `map $http_authorization $mcp_role` มาเป็น
  `proxy_pass` ไปที่ `mcp-auth` · **seam นี้มีอยู่แล้ว** เพราะ config เดิมเรียก `auth_request` อยู่ก่อน
- `auth_request_set` ดึง `X-Actor*` จากคำตอบ แล้วส่งต่อให้ฮับผ่าน `mcp_proxy.conf`
- access log เปลี่ยนจากพิมพ์ role มาเป็นพิมพ์ตัวตน — role บอกอะไรไม่ได้เมื่อหลายคนใช้ path เดียวกัน
- ลบ `map` ของโทเคนทิ้ง เพราะถ้าเหลือไว้ วันหนึ่งจะมีคนต่อมันกลับเข้าไปข้าง verifier ที่ตัดสินไม่ตรงกัน
- service `mcp-auth` ใน compose · เว้น `AUTH_JWT_*` ว่างไว้ = พฤติกรรมเดิมทุกอย่าง (Bearer อย่างเดียว)

## ผลที่รันจริง

**unit — `npm run smoke -w @itops/mcp-auth`** เซ็นโทเคนด้วยคีย์ทดสอบในเครื่อง ไม่แตะเครือข่าย:
ผ่านทั้งชุด ครอบ static ทั้งสาม role, ตัวตนที่ map แล้วและยังไม่ map, หมดอายุ, ผิด issuer,
ผิด audience, ไม่รู้จัก kid, payload ถูกแก้ · JWKS ถูกดึง **1 ครั้ง** ตลอดชุดแรก · และรอบหลัง
เพิ่มตามเกณฑ์ใน dis-bc779b20 seq 10: **cooldown** (โทเคน kid ไม่รู้จัก 5 ใบติดกันไม่ทำให้ดึง
keyset เพิ่มแม้แต่ครั้งเดียว), **rotation** (คีย์ใหม่ถูกรับหลังหมด cooldown โดยคีย์เก่ายังใช้ได้),
**outage** (JWKS ล่มตอบ 503 ไม่ใช่ 401 คีย์ที่ cache ไว้ยังตรวจได้ และเส้น static ไม่กระทบ)

**regression — `./scripts/smoke-test.sh` ของฮับ** บน sandbox ที่ยก verifier ขึ้นแล้ว:
**26 passed / 4 failed** โดยทั้ง 4 ที่ตกคือ `ACCOUNTING → 502` ซึ่งเป็นผลจากที่ sandbox นี้
**ตั้งใจไม่ยก** `mcp-hub-accounting` ขึ้น ไม่ใช่ผลจากการเปลี่ยน auth — เคส RBAC ทุกเคส (401/403)
ผ่านครบผ่าน verifier ตัวใหม่

**end-to-end — ยิงผ่าน Nginx จริง** ดู `../../evidence/jwt-auth-matrix.txt`:

| กรณี | ผล |
| --- | --- |
| โทเคน static IT / ADMIN → `/mcp/it` | 200 / 200 (ADMIN ใช้ path IT ได้เหมือนเดิม) |
| โทเคน static ACCOUNTING → `/mcp/it` | 403 |
| JWT alice (role it) → `/mcp/it` | 200 |
| JWT alice → `/mcp/admin` · `/mcp/accounting` | 403 · 403 |
| JWT bob (role admin) → `/mcp/admin` · `/mcp/it` | 200 · 200 |
| JWT ที่ยังไม่ map role → `/mcp/it` | 403 |
| JWT หมดอายุ / ผิด audience / ผิด issuer / ขยะ / ไม่มีโทเคน | 401 ทุกกรณี |

session MCP เต็มรูปแบบด้วย JWT: `tools/list` ได้ 24 tools และเรียก `rag_get_status` ได้จริง

และที่เป็นหัวใจของงานนี้ — access log ของฮับเปลี่ยนจากพิมพ์ role มาเป็นพิมพ์คน:

```
172.24.0.1 jwt:alice@example.test POST /mcp HTTP/1.1 200 1250 rt=0.142
172.24.0.1 jwt:bob@example.test   POST /mcp HTTP/1.1 200  191 rt=0.014
172.24.0.1 static:token:it        POST /mcp HTTP/1.1 200  188 rt=0.012
```

## เกณฑ์เพิ่มเติมจาก seq 10 — ผลอยู่ใน `../../evidence/seq10-hardening.txt`

**header spoofing** — วัดของจริงด้วยการสลับ `mcp-hub-it` เป็น echo server ชั่วคราวแล้วสลับกลับ:
ค่าที่ caller ส่งมาเอง (`X-Actor`, `X-Actor-Source`, `X-MCP-Role`) ถูกทับทุกกรณี upstream เห็น
เฉพาะค่าที่ verifier ออกให้

**bypass** — ไม่มี credential แล้วลอง 9 เส้นทาง (`//`, `..`, `%2e%2e`, `/.`, ตัวพิมพ์ใหญ่,
`/_auth_it` ตรง ๆ, exact path ที่ไม่มี trailing slash) ไม่มีเส้นไหนถึง upstream ได้

**invalid JWT ไม่ fallback** — ลายเซ็นพัง / ไม่มีลายเซ็น / `alg=none` ได้ 401 ทั้งหมด ขณะที่
static IT และ JWT ที่ถูกต้องได้ 200 · เส้น static เทียบแบบตรงตัวก่อนเสมอ โทเคนที่เป็น JWT จึง
ไม่มีทางไปชนเส้น static ได้

**audit** — การปฏิเสธระบุตัวคนได้แล้วในบรรทัดเดียวของ access log (`jwt-denied:<principal>`,
`static-denied:token:<role>`) และ grep หาโทเคนทั้งสามใบกับ JWT เต็มสตริงใน log ของ nginx และ
mcp-auth รวมกัน พบ **0 ครั้ง**

## บั๊กที่ชุดทดสอบใหม่จับได้

JWKS ที่ดึงไม่สำเร็จเคยถูกโยนเป็น `JwtVerificationError` ซึ่งแอปตีความเป็น "โทเคนไม่ผ่าน" แล้ว
ตอบ 401 — ขัดกับที่ comment ในโค้ดเขียนไว้เอง แก้โดยแยกเป็น `JwksUnavailableError` ต่างหาก
(ครอบทั้ง HTTP error, keyset เพี้ยน และ transport ล้มเหลว) แอปจึงตอบ 503 ตามเจตนา
ไม่ไปบอกผู้ใช้ว่าโทเคนของเขาเสีย

## ที่ยังไม่ได้ทำ ต้องทำก่อนขึ้นไซต์

1. **audience binding ยังไม่ถูกต้องตามสเปก** — seq 10 ทักไว้ตรงจุด: ถ้า token ถูกออกให้ gateway
   เท่านั้น การตั้ง `AUTH_JWT_AUDIENCES` ให้รับ audience ของ gateway ที่ upstream คือการดัดค่าให้
   ผ่าน ไม่ใช่การทำให้ถูก ทางที่ถูกคือ token exchange หรือให้ upstream เป็นผู้ออก token เอง —
   ต้องเก็บหลักฐานว่า gateway รองรับแบบไหนก่อน แล้วจึงเสนอ **ยังไม่ทำในรอบนี้**
2. **ยังไม่เคยเจอโทเคนจริงของ gateway** — และ PAT ของ TrueFoundry เป็น opaque ไม่ใช่ JWT
   (ตรวจแล้ว) สมมติฐาน "รับ JWT แล้ว verify จาก JWKS" จึงยังไม่ครอบ credential ทุกชนิดที่ขาเข้า
   รองรับ ต้องดูของจริงจากเส้น OAuth ก่อน และหา stable principal identifier ที่ใช้ได้จริง
   (`iss` + `sub`) แทนการใช้ email เป็นตัวระบุถาวร
3. **ฮับยังไม่อ่าน `X-Actor`** — Nginx ส่งให้แล้วและ access log พิสูจน์แล้วว่ามีค่าจริง แต่
   `mcp-hub` ยังไม่เอาไปลง log ของตัวเอง
4. **การ map principal → role** ตอนนี้เป็น JSON ใน env เหมาะกับคนไม่กี่คน ถ้าจะโตต้องมีที่เก็บจริง

## วิธีลองซ้ำ

ยก sandbox ตาม `../../docs/poc/dual-mcp-runbook.md` §1 แล้วเอา `mcp-auth/` ไปวางที่
`packages/mcp-auth` ของ hub, apply `wiring.diff`, เพิ่ม `packages/mcp-auth` ลง `workspaces`
แล้ว build ใหม่ · ตั้ง `AUTH_JWT_*` ให้ชี้ JWKS ที่ตัวเองคุมได้เวลาทดสอบ ส่วน production ชี้ไปที่
JWKS ของ gateway
