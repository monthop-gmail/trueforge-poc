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

# TrueFoundry — ต้องทำผ่านหน้าเว็บแล้ว เพราะ PAT ถูกเพิกถอนไปเมื่อ 18 ก.ย. 2026
#   ลบ connector poc-collab-readonly
#   ลบ virtual account poc-noaccess (ยัง authenticate ได้แต่ไม่มีสิทธิ์อะไรเลย)
#   ถ้าจะกลับมาใช้ API ต้องออก PAT ใบใหม่ก่อน

# ในเครื่อง
docker compose -p itops-poc down -v
pkill -f '@truefoundry/trueforge'; pkill -f 'wrangler dev'
rm -f .env.tfy vendor/itops-mcp-hub/.env <clone ของ collab>/.dev.vars
```

secret ของชุดทดสอบเป็นคนละใบกับของจริงตั้งแต่ต้น · การลบจึงไม่ต้องเพิกถอนอะไรฝั่ง production

## 4.1 PAT ของ TrueFoundry — **เพิกถอนแล้ว 18 ก.ย. 2026**

| ใบ | id | ผล |
|---|---|---|
| `poc-trueforge` | `nl5i4kdk…` | ลบแล้ว |
| `poc-trueforge-noaccess` | `bpapovo2…` | ลบแล้ว |
| `default-jl9t3n2n…` | — | **ไม่แตะ** — ใบที่ระบบสร้างตอนสมัคร ไม่ใช่ของงานนี้ |

ยืนยันด้วยการยิงจริง ไม่ใช่แค่หายจากรายการ — เรียก `GET /v1/personal-access-tokens`
ด้วยโทเคนเดิมแล้วได้ **401 `Invalid or expired token`**

**ผลที่ตามมาและต้องรู้:** resource ทดสอบบน TrueFoundry ที่ยังคงไว้
(connector `poc-collab-readonly`, virtual account `poc-noaccess`)
**จัดการผ่าน API ไม่ได้อีกแล้ว** ต้องเข้าหน้าเว็บ หรือออก PAT ใบใหม่

`TFY_VA_NOACCESS` เป็น virtual account คนละชนิดกับ PAT · ยัง authenticate ได้
(ตอบ 403 ไม่ใช่ 401) แต่ไม่มี role binding ใด ๆ จึงทำอะไรไม่ได้เลย
ซึ่งเป็นสภาพที่ตั้งใจไว้ตั้งแต่แรก — ถ้าจะลบต้องทำผ่านหน้าเว็บ

**`RYNST_IT_TOKEN` ไม่ถูกแตะ** — ตรวจแล้วยังใช้งานได้จริง (200)
เป็นโทเคนของไซต์ ไม่ใช่ของ PoC และไม่ใช่สิทธิ์เราที่จะเพิกถอน
ถ้าไซต์ไม่ต้องการให้เครื่องนี้ถือต่อ ให้เจ้าของไซต์หมุนโทเคนฝั่งเขา

## 5. ข้อห้ามระหว่างที่ยังคงของไว้

ห้ามเพิ่มสิทธิ์ให้ของทดสอบ · ห้ามผูก custom domain · ห้ามใส่ production secret ·
ห้ามชี้ไปที่ข้อมูลไซต์จริง · ห้ามเชื่อ workspace จริงเข้ากับ deployment ทดสอบ
