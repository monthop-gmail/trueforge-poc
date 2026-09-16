# ทะเบียนของที่สร้างไว้เพื่อทดสอบ และวิธีรื้อ

บันทึกตาม dis-bc779b20 seq 26 ข้อ 6 · ของทั้งหมดในใบนี้เป็น **ของทดสอบ** ที่สร้างใหม่
แยกจากของจริง · ไม่มีค่าจริง (token, id, hostname) อยู่ในไฟล์นี้

ปรับปรุงล่าสุด: 17 ก.ย. 2026 · สถานะ: **คงไว้ตามคำสั่ง seq 26** ยังไม่รื้อ

## 1. บัญชี Cloudflare

| ของ | ชื่อ | หมายเหตุ |
| --- | --- | --- |
| Worker | `ai-collaboration-mcp-poc` | `workers.dev` เท่านั้น ไม่ผูก custom domain · `preview_urls: false` |
| D1 | `ai-collab-poc` | ฐานใหม่ seed จาก `schema.sql` เท่านั้น ไม่เคยเชื่อมกับ workspace จริง |
| KV namespace | สร้างใหม่สำหรับ `OAUTH_KV` ของ Worker ทดสอบ | แยกจากของจริงเพราะเก็บ client/grant/token ของ OAuth |
| secret | `MCP_AUTH_TOKEN`, `MCP_AUTH_TOKENS`, `MCP_READONLY_TOKENS` | สร้างสดทั้งสามตัว ไม่ใช้ซ้ำของ production |

ของจริงที่ **ไม่ถูกแตะ**: Worker ของจริง · D1 `ai-collab` · KV ของจริง · โดเมนที่ผูกไว้ · secret ของจริง

## 2. TrueFoundry tenant

| ของ | ชื่อ | หมายเหตุ |
| --- | --- | --- |
| connector | `poc-collab-readonly` | header auth ด้วย RO token ของชุดทดสอบ ชี้ไป `/mcp-readonly` ของ Worker ทดสอบ |
| virtual account | `poc-noaccess` | ไม่มี role binding ใด ๆ ใช้พิสูจน์ว่า gateway ปฏิเสธผู้ไม่มีสิทธิ์ |
| role binding | ไม่มีเหลือ | ใบที่สร้างตอนทดสอบการให้/ถอนสิทธิ์ ถูกลบแล้ว |

connector ของจริงสองตัวยังอยู่ตามเดิม ไม่ได้แก้สิทธิ์หรือ credential

## 3. ในเครื่องที่ทีมใช้รัน

| ของ | ที่อยู่ | หมายเหตุ |
| --- | --- | --- |
| sandbox ของฮับ | compose project `itops-poc` | 11 container พอร์ตเลื่อนทั้งชุด fixture ล้วน |
| Worker ในเครื่อง | `wrangler dev` + D1 ในเครื่อง | ใช้พัฒนา ไม่เกี่ยวกับของบนคลาวด์ |
| branch ของ collab | `poc/readonly-route` ใน clone ของทีม | ยังไม่ push ยังไม่เปิด PR |
| branch ประวัติเก่า | `pre-public-history` ใน repo นี้ | มีชื่อโฮสต์จริง **ห้าม push ขึ้น repo สาธารณะ** |
| ไฟล์ env | `.env.tfy`, `.env` ของ sandbox, `.dev.vars` | gitignore ทั้งหมด `0600` |

## 4. วิธีรื้อ เมื่อถึงเวลา

```bash
# Cloudflare
wrangler delete --name ai-collaboration-mcp-poc
wrangler d1 delete ai-collab-poc
wrangler kv namespace delete --namespace-id <id ของ KV ทดสอบ>

# TrueFoundry — ลบ connector และ virtual account ที่ใช้ทดสอบ
#   DELETE /api/svc/v1/mcp/<id ของ poc-collab-readonly>
#   ลบ virtual account poc-noaccess ถ้าไม่ใช้ต่อ

# ในเครื่อง
docker compose -p itops-poc down -v
pkill -f '@truefoundry/trueforge'; pkill -f 'wrangler dev'
rm -f .env.tfy vendor/itops-mcp-hub/.env <clone ของ collab>/.dev.vars
```

secret ของชุดทดสอบเป็นคนละใบกับของจริงตั้งแต่ต้น · การลบจึงไม่ต้องเพิกถอนอะไรฝั่ง production
สิ่งเดียวที่ต้องเพิกถอนแยกคือ **PAT ของ TrueFoundry** ที่ใช้ทำ PoC ทั้งรอบ

## 5. ข้อห้ามระหว่างที่ยังคงของไว้

ห้ามเพิ่มสิทธิ์ให้ของทดสอบ · ห้ามผูก custom domain · ห้ามใส่ production secret ·
ห้ามชี้ไปที่ข้อมูลไซต์จริง · ห้ามเชื่อ workspace จริงเข้ากับ deployment ทดสอบ
