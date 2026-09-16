# trueforge-poc

PoC ของทีม `monthop-gmail/trueforge`: ต่อ MCP server สองตัว — โต๊ะงานร่วม (collaboration workspace)
กับฮับงาน IT — ให้ถึงได้จริงจาก TrueForge harness และจาก TrueFoundry AI Gateway โดยมี auth,
RBAC และตัวตนที่อธิบายได้

ผลสรุป: เส้นทางตรง **ผ่าน** · เส้นทาง gateway **ผ่าน** บน TrueFoundry แผน Developer (ฟรี) —
แต่ *gateway authorization* ยังไม่ได้ทดสอบ และ gateway OAuth ยังติดกติกา PKCE ของฮับอยู่

อ่าน `docs/poc/dual-mcp-results.md` ก่อน เพราะเป็นใบที่มีตาราง acceptance และข้อค้นพบทั้งหมด ·
`docs/poc/dual-mcp-overview.md` เก็บ topology กับ version ที่ปักหมุดไว้ ·
`docs/poc/dual-mcp-runbook.md` สร้างทุกอย่างขึ้นมาใหม่ได้จากศูนย์

```
scripts/smoke-bearer.sh      Bearer ทางตรงของทั้งสอง server + negative auth/RBAC
scripts/probe-oauth.sh       OAuth discovery ทั้งสองฝั่ง; code+PKCE+refresh เต็มรูปแบบบน sandbox
scripts/probe-trueforge.sh   server สองตัวเดิม แต่ให้ TrueForge harness เป็นคนต่อ
scripts/probe-gateway.sh     server สองตัวเดิม แต่ผ่าน TrueFoundry AI Gateway
evidence/                    output ดิบของการรันจริงทั้งสี่ชุด
```

ไม่มีสคริปต์ตัวไหนพิมพ์โทเคนออกมา การเทียบความลับใช้ SHA-256 prefix เท่านั้น · flow ที่ต้อง
ลงทะเบียน OAuth client เป็นแบบ opt-in (`ITOPS_RUN_FLOW=1`) และตั้งใจให้ใช้กับ sandbox ของตัวเอง

source ของ upstream อยู่ใต้ `vendor/` และไม่ถูก commit — ปักหมุดด้วย SHA ไว้ในใบ overview แทน

> ฉบับสาธารณะนี้แทนชื่อโฮสต์จริงและชื่อ tenant ด้วย placeholder (`<collab-host>`,
> `<itops-site-host>`, `<tenant>`, `<site>`) ค่าจริงอยู่ในโต๊ะงานของทีม ไม่ได้อยู่ใน repo นี้
