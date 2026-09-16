# Runbook — deployment ทดสอบของ ai-collaboration-mcp

เตรียมไว้ตาม dis-bc779b20 seq 22 · **ยังไม่ deploy และยังไม่สร้าง secret จริง**
ทุกอย่างในใบนี้คือสิ่งที่จะทำ *หลัง* เจ้าของงานอนุมัติ ไม่ใช่สิ่งที่ทำไปแล้ว

## สิ่งที่จะสร้าง และสิ่งที่จะไม่แตะ

| จะสร้างใหม่ | ชื่อที่เสนอ |
| --- | --- |
| Worker สำหรับทดสอบ | `ai-collaboration-mcp-poc` |
| ฐาน D1 ใหม่ | `ai-collab-poc` |
| secret ของ Worker ทดสอบ | `MCP_AUTH_TOKEN`, `MCP_AUTH_TOKENS`, `MCP_READONLY_TOKENS` — สร้างสดตอน deploy |
| ที่อยู่สาธารณะ | `workers.dev` ของ Worker ตัวนี้เท่านั้น |

**จะไม่แตะ**: Worker ของจริง · ฐาน D1 ของ workspace จริง · โดเมนที่ผูกไว้ · secret ของจริง ·
และจะไม่ใช้ `ws-001` เป็นฐานของการทดสอบ write หรือ negative ใด ๆ

ชื่อทั้งสองปรับได้ตามที่เจ้าของงานกำหนด ใบนี้ล็อกแค่รูปแบบ ไม่ได้ล็อกชื่อ

## ขั้นตอน (รันหลังได้รับอนุมัติเท่านั้น)

```bash
cd <clone ของ ai-collaboration-mcp>            # branch poc/readonly-route
wrangler whoami                                 # ยืนยันว่าเป็นบัญชีที่ตั้งใจ

# 1. ฐานใหม่ แล้วจดค่า database_id ที่ได้กลับมา
wrangler d1 create ai-collab-poc

# 2. config แยกไฟล์ ไม่แก้ wrangler.jsonc ของจริง
#    name = ai-collaboration-mcp-poc, d1_databases[0].database_id = ค่าจากขั้น 1
#    workers_dev = true และไม่ใส่ routes/custom domain
cp wrangler.jsonc wrangler.poc.jsonc            # แล้วแก้สามจุดข้างต้น

# 3. schema ลงฐานใหม่
wrangler d1 execute ai-collab-poc --remote --file schema.sql --config wrangler.poc.jsonc

# 4. secret สร้างสดตรงนี้ ไม่ใช้ซ้ำของเดิม ไม่เขียนลงไฟล์ ไม่ส่งเข้าโต๊ะ
#    รูปแบบของสองตัวหลังคือ `<token>=<ชื่อที่จะบันทึก>` คั่นด้วย comma
openssl rand -hex 24                            # -> RW
openssl rand -hex 24                            # -> RO
wrangler secret put MCP_AUTH_TOKEN      --config wrangler.poc.jsonc
wrangler secret put MCP_AUTH_TOKENS     --config wrangler.poc.jsonc
wrangler secret put MCP_READONLY_TOKENS --config wrangler.poc.jsonc

# 5. deploy
wrangler deploy --config wrangler.poc.jsonc
```

## Acceptance ที่จะรัน

```bash
COLLAB_BASE=https://ai-collaboration-mcp-poc.<subdomain>.workers.dev \
COLLAB_RO_TOKEN=<RO> COLLAB_RW_TOKEN=<RW> COLLAB_ALLOW_WRITE_PROBE=1 \
  ./scripts/probe-collab-readonly.sh
```

สคริปต์เดียวกับที่ใช้กับ Worker ในเครื่องแล้วได้ **21 passed / 0 failed** ครอบ route × credential
matrix, การที่เส้นอ่านตอบ 401 เองแทนที่จะตกไป OAuth, tools/list ที่ซ่อน write tool, การปฏิเสธ
write tool ทั้งเก้าตัวเมื่อเรียกตรง ๆ ด้วย argument ที่ valid, bypass เจ็ดรูปแบบ, handler-cache
isolation และ regression ของเส้นปกติ

`COLLAB_ALLOW_WRITE_PROBE` ปิดไว้เป็นค่าตั้งต้น เปิดเฉพาะกับ workspace ที่ทิ้งได้

เพิ่มอีกสองอย่างที่ทำได้เฉพาะบน deployment จริง และไม่มีใน local:
- **redeploy** แล้วรันสคริปต์ซ้ำ ผลต้องเท่าเดิมทุกข้อ
- **cold start** — ยิงครั้งแรกหลัง redeploy ต้องไม่ต่างจากการยิงตอน warm

## Teardown

```bash
wrangler delete --name ai-collaboration-mcp-poc
wrangler d1 delete ai-collab-poc
```
แล้วทิ้งค่า RW/RO ที่สร้างไว้ · ไม่มีอะไรค้างในบัญชี และไม่มีอะไรที่ต้องเพิกถอนฝั่งของจริง
เพราะ secret ของ Worker ทดสอบเป็นคนละชุดตั้งแต่ต้น

## หลักฐานที่จะเก็บ

output ของสคริปต์ทั้งก่อนและหลัง redeploy ลง `evidence/` โดยแทน hostname จริงและ subdomain
ด้วย placeholder ตามกติกาของ repo สาธารณะ · ไม่มี token ในไฟล์ใด ๆ

## ข้อจำกัดที่ต้องระบุคู่กับผล

deployment นี้พิสูจน์ **shared credential per route** ไม่ใช่ per-user identity — upstream ยังเห็น
ตัวตนเดียวต่อหนึ่ง credential ตามที่ seq 20 กำชับว่าห้ามเรียกผลรอบนี้ว่า per-user identity E2E
