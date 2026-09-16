# prototype สำหรับ ai-collaboration-mcp — เส้นทางอ่านอย่างเดียว

ข้อเสนอสำหรับ `monthop-gmail/ai-collaboration-mcp` · **ยังไม่ push ยังไม่เปิด PR และไม่แตะ
deployment จริง** ทั้งหมดทดสอบบน Worker ในเครื่อง (`wrangler dev --local`) กับ D1 ในเครื่อง

## หลักออกแบบที่ทีมล็อกไว้ (dis-bc779b20 seq 18)

path แยก + credential ผูกกับ path + deny-by-default · การผูกคือ **token → route/capability**
ไม่ใช่ token → participant identity ซึ่งยังพักไว้จนกว่า dec-f7bdf7fa จะได้ข้อสรุป

## สิ่งที่เพิ่ม

`src/readonly.ts` — allowlist ของ tool อ่าน 6 ตัว และ Proxy ที่ครอบ `registerTool`
tool ที่ไม่อยู่ในลิสต์จะถูกลงทะเบียนแล้ว **`disable()`** ทันที

เลือก `disable()` แทนการไม่ลงทะเบียน เพราะได้ทั้งสองชั้นที่ทีมขอพร้อมกัน:
SDK กรอง tool ที่ disabled ออกจาก `tools/list` (ชั้น discovery) และตอบ
`Tool <name> disabled` เมื่อมีคนเรียกตรง ๆ (ชั้น enforcement) — เป็นการปฏิเสธที่ระบุชื่อ tool
ไม่ใช่ `unknown tool` ที่แยกไม่ออกจากการพิมพ์ผิด

`src/index.ts` — route `/mcp-readonly` แยกจาก `/mcp` · `MCP_READONLY_TOKENS` เป็นรายการ
credential คนละใบ · handler cache ใส่เส้นทางเป็นส่วนหนึ่งของ key ไม่งั้น handler ของเส้นหนึ่ง
จะถูกหยิบไปใช้กับอีกเส้นแล้ว server ที่ปิด tool ไว้จะกลายเป็นเปิด · เส้น read-only ไม่ผูกกับ
OAuth provider จึงตอบ 401 เองเมื่อรหัสไม่ผ่าน แทนที่จะตกไปให้ provider พาไป flow ของเส้นปกติ

`src/env.ts` — ประกาศ `MCP_READONLY_TOKENS`

`test/readonly.test.ts` — regression test ถาวร 16 เคส ครอบสองกรณีที่ seq 20 สั่งให้ตรึงไว้
โดยเฉพาะ: **cache ของ handler ต้องแยกตามเส้นทาง** (เรียกเส้นปกติก่อนแล้วเส้นอ่าน ต้องไม่ได้ tool
ชุดของเส้นปกติมา) และ **เส้นอ่านต้องไม่ตกไปที่ OAuth provider ของเส้นปกติ** (รหัสไม่ผ่านต้องได้
401 ของเส้นนี้เอง พร้อม detail ที่อ้าง `MCP_READONLY_TOKENS`) · ที่เหลือคือ route/credential
matrix, การซ่อน write tool จาก tools/list และการปฏิเสธ write tool ทั้งเก้าตัวเมื่อเรียกตรง ๆ

รวม **2 ไฟล์แก้ 59 เพิ่ม 7 ลบ** และไฟล์ใหม่ 2 ไฟล์ (`src/readonly.ts`, `test/readonly.test.ts`)

## ผลทดสอบ

`npx vitest run` ทั้ง repo: **181 tests ผ่านทั้งหมด** (เดิม 165 + ใหม่ 16) ไม่มีเคสเดิมถอยหลัง

หลักฐานจากการยิงจริงเต็มอยู่ใน `../../evidence/readonly-collab.txt` · สรุป: route/credential matrix แยกขาดทั้งสองทาง ·
`tools/list` บนเส้น read-only เห็น 6 tool อ่านเท่านั้น ไม่มี write tool โผล่ · เรียก write tool
ทั้งเก้าตัวด้วยชื่อจริงและ argument ที่ valid ถูกปฏิเสธทั้งหมด · bypass/normalization 7 แบบไม่ผ่าน ·
policy คงอยู่หลัง restart · เส้นปกติยังเขียนได้เหมือนเดิม · `npm run typecheck` ผ่าน

## ที่ยังไม่ได้ทำ

ยังไม่ได้ทดสอบกับ deployment ทดสอบหรือของจริง · ยังไม่ได้ผูกกับ OAuth (เส้น read-only รองรับ
static bearer อย่างเดียวในรอบนี้) · การ classify tool เป็นรายชื่อใน allowlist ถ้า tool ใหม่ถูก
เพิ่มเข้ามาจะถูกปฏิเสธโดยอัตโนมัติ ซึ่งเป็นพฤติกรรมที่ตั้งใจ แต่แปลว่าต้องมีคนมาต่อรายการ

## วิธีลองซ้ำ

```bash
git checkout -b poc/readonly-route            # ใน clone ของ ai-collaboration-mcp
# วาง readonly.ts ลง src/ แล้ว apply wiring.diff
cat > .dev.vars <<'ENV'
MCP_AUTH_TOKEN=<rw>
MCP_AUTH_TOKENS=<rw>=team-name
MCP_READONLY_TOKENS=<ro>=team-name-readonly
ALLOWED_ORIGIN_HOSTNAMES=*
ENV
npm run db:local && npx wrangler dev --port 8788 --local
```
