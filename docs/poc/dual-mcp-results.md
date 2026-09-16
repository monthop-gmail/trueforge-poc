# Dual MCP PoC — ผลการทดสอบ

รอบ 1 รันวันที่ 16 ก.ย. 2026 (เส้นทางตรง) · รอบ 2 เย็นวันเดียวกันหลังเจ้าของงานเปิด tenant
TrueFoundry แผน Developer แบบฟรี ทำให้ปิดเส้นทาง gateway ได้ · output ดิบอยู่ใน `evidence/`
ทุกตัวเลขข้างล่างมาจากสคริปต์ใน `scripts/` ไม่มีข้อไหนอนุมานจาก source

## สถานะแยกตามเส้นทาง

| เส้นทาง | สถานะ | อ้างอิงจาก |
| --- | --- | --- |
| **Bearer ทางตรง** (ทั้งมีและไม่มี TrueForge harness) | **PASS** | `smoke-bearer.sh` 14/0, `probe-trueforge.sh` 11/0 |
| **OAuth ทางตรง** — ฮับ IT Ops | **PASS** | `probe-oauth.sh` 13/0 + code flow เต็มรูปแบบที่ TrueForge เป็นคนขับเอง |
| **OAuth ทางตรง** — Collaboration | **NOT RUN** | discovery ผ่าน แต่ DCR จะไปลงทะเบียน client บน Worker production ที่ใช้ร่วมกัน |
| **Bearer ผ่าน gateway** (credential แบบ header ที่ connector) | **PASS** | `probe-gateway.sh` 12/0 — ทั้งสอง server บน tenant จริง |
| **OAuth ผ่าน gateway** | **BLOCKED** | gateway ไม่ส่ง PKCE และโฮสต์ redirect ของมันไม่อยู่ใน allowlist ของฮับ — ดูข้อค้นพบ 6 |
| **Authorization ของ gateway** (ผู้ที่ควรถูกปฏิเสธ) | **PASS** | `evidence/gateway-authorization.txt` — ข้อค้นพบ 9 |
| **การกรอง tool ราย tool บน Virtual MCP** | **FAIL** | manifest เก็บ subset ไว้แต่ไม่ถูกบังคับใช้ — ข้อค้นพบ 10 |

## Acceptance criteria

| AC | ผล | หลักฐาน |
| --- | --- | --- |
| AC1 topology + version + ขั้นตอนเริ่มระบบที่ทำซ้ำได้ | **PASS** | `dual-mcp-overview.md` §2, `dual-mcp-runbook.md` · เหลือช่องโหว่เดียว: Worker ของ collaboration ปักหมุดเป็น commit จากภายนอกไม่ได้ |
| AC2 initialize + tools/list + เรียก read อย่างน้อยหนึ่งตัว ทั้งสอง server | **PASS (ทางตรงและผ่าน gateway)** / **PARTIAL (ผ่าน harness)** | ทางตรงและผ่าน gateway: collab 15 tools + IT 24 tools เรียก read จริงได้ทั้งคู่ · ผ่าน TrueForge: discover ได้จำนวนเท่ากัน แต่ "เรียก" tool เป็น **NOT RUN** เพราะ harness ไม่มี API เรียก tool นอก agent turn ซึ่งต้องมี model provider |
| AC3 ไม่มี/ผิดโทเคนถูกปฏิเสธ · โทเคน IT ถูกปฏิเสธที่ admin และ accounting | **PASS (ทางตรงและ gateway)** | ทางตรง: 401 ทั้งกรณีไม่มีและผิดโทเคนที่ทั้งสอง server, 403 สำหรับโทเคน IT ที่ `/mcp/admin` และ `/mcp/accounting` · gateway: 401 เมื่อไม่มีหรือใช้ PAT ผิดทั้งสอง connector และ connector ที่ชี้โทเคน IT ไปที่ path admin ถูกปฏิเสธ `403 "This token cannot access this MCP path"` — แต่ 403 ก้อนนั้นคือ RBAC ของ upstream ที่โผล่ผ่าน gateway ออกมา ไม่ใช่ gateway policy · **gateway policy เองพิสูจน์แยกแล้วในข้อค้นพบ 9** จึงนับเป็น PASS ทั้งสองชั้น |
| AC4 tools/list ของ IT ไม่มี privileged shell | **PASS (ทางตรงและผ่าน gateway)** | 24 tools ไม่มีตัวไหนเข้าข่าย `run_shell`/`exec`/`command` และไม่ได้เรียก shell จริง |
| AC5 identity บน collaboration ตรงกับตัวตนของทีม | **PASS แต่มีข้อสังเกตที่สำคัญ** | `you_are=monthop-gmail/trueforge` ทั้งเส้นทางตรงและผ่าน gateway และ handoff ถูกรับด้วยชื่อเดียวกัน · เป็น **service/team identity ไม่ใช่ human หรือ model identity** — ดูข้อค้นพบ 1 |
| AC6 ทดสอบ OAuth ทั้งสอง server พร้อมบันทึก refresh และ restart | **PASS (IT Ops ทางตรง)** / **NOT RUN (collab)** / **BLOCKED (gateway)** | ทางตรง: DCR → PKCE S256 → consent → code → token → tools/list → refresh ผ่านหมด · code ที่ถูกเล่นซ้ำด้วย verifier ผิดถูกปฏิเสธ · พฤติกรรมตอน restart อยู่ในข้อค้นพบ 3 · OAuth ผ่าน gateway ดูข้อค้นพบ 6 |
| AC7 แยกหลักฐานรายชั้นได้ ไม่มี credential ใน log | **PASS** | หลักฐานของฮับ, harness และ gateway อยู่คนละไฟล์ · สคริปต์ไม่พิมพ์โทเคนและเทียบความลับด้วย SHA-256 prefix |
| AC8 demo: อ่าน IT → สรุป → บันทึกลง collaboration | **PARTIAL** | อ่าน IT จริงและเขียนกลับจริง (คือรายงานฉบับนี้) แต่เขียนลง workspace **ที่ใช้ร่วมกัน** เพราะไม่มี deployment ทดสอบของ collaboration |
| AC9 การเก็บกวาดไม่กระทบของจริง | **PASS** | sandbox เป็น compose project ของตัวเอง พอร์ตเลื่อน โทเคนสร้างเอง · connector ที่สร้างเพื่อทดสอบ cross-role ถูกลบทิ้งหลังทดสอบ เหลือ connector ตามตั้งใจสองตัวพอดี |

ยอดรวมการรัน: `smoke-bearer` 14/0 · `probe-oauth` 13/0 · `probe-trueforge` 11/0 · `probe-gateway` 12/0

## ข้อค้นพบ

### 1. บน collaboration MCP โทเคน static ไม่ได้กำหนดว่าคุณเป็นใคร

โทเคนใบเดียวกัน ยิงสามครั้ง ได้คำตอบจาก `get_workspace_context.you_are` สามค่า:

| `X-Client-Name` ที่ส่ง | identity ที่ได้ |
| --- | --- |
| `monthop-gmail/trueforge` | `monthop-gmail/trueforge` |
| *(ไม่ส่ง header)* | `Claude Code` |
| `poc-identity-probe` | `poc-identity-probe` |

ชื่อเป็นสิ่งที่ **ผู้เรียกประกาศเอง ไม่ได้ผูกกับโทเคน** ความน่าเชื่อถือของ authorship ในโต๊ะจึงเท่ากับ
ความน่าเชื่อถือของทุกคนที่ถือโทเคนใบนั้น · การทดลองจงใจใช้ชื่อที่ไม่มีใครเป็นเจ้าของ ไม่ได้สวมชื่อ
participant ที่มีอยู่จริง

รอบ 2 ทำให้ข้อนี้คมขึ้น ไม่ใช่เบาลง: ตอนนี้ gateway ส่ง header นั้นแทนทุกคนที่เรียก connector
upstream จึงเห็นชื่อเดียวทั้งทีม การแยกรายคนมีอยู่แค่ในบันทึกของ gateway เท่านั้น

*ข้อเสนอ:* ผูก identity กับโทเคนที่ฝั่ง server และให้ `X-Client-Name` ทำได้แค่ "แคบลง" ไม่ใช่ "เลือก" ตัวตน

### 2. access_token ที่ OAuth ของฮับออกให้ *คือ* โทเคนบทบาทใบเดิม

หลังแลก authorization code จนครบขั้นตอน `access_token` ที่ได้มี SHA-256 prefix ตรงกับ `IT_TOKEN`
แบบ static · response ประกาศ `expires_in: 28800` แต่ค่าที่ส่งมอบคือความลับใบยาวใบเดิมที่ Nginx
ใช้เทียบ อายุที่ประกาศจึงเป็นแค่คำบรรยาย: เพิกถอน client รายตัวไม่ได้ถ้าไม่เพิกถอนทั้งหมด,
บังคับ expiry ที่ชั้น Nginx ไม่ได้ และใน audit แยกไม่ออกว่าโทเคนมาจาก OAuth หรือจากคนแปะเอง

ข้อนี้ยังเป็นเหตุผลว่าทำไมการเลือก header auth ที่ gateway (ข้อค้นพบ 7) ไม่ได้เสียอะไรในเชิงความปลอดภัย
— เส้น OAuth ก็จะส่งมอบความลับก้อนเดียวกันอยู่ดี

### 3. state ของ OAuth อยู่ใน memory · restart แล้วหาย ส่วน Bearer ไม่กระทบ

refresh token ที่ออกก่อน `docker compose restart mcp-oauth` พอ restart เสร็จจะได้ `invalid_client`
ขณะที่ทาง static Bearer ตอบ 200 ตลอดช่วงเดียวกัน · ระหว่างวินาทีที่ service ลง `/authorize` กับ
`/token` ตอบ 502 แต่ `/mcp/it/mcp` ยังเสิร์ฟปกติ

agent ที่ต่อด้วย OAuth จะหลุดทุกครั้งที่ deploy ส่วนตัวที่ต่อด้วย Bearer ไม่หลุด · เป็นข้อจำกัดที่
คาดไว้ของ MemoryStore ไม่ใช่ regression แต่ทำให้ OAuth เป็นเส้นทางที่เสถียรน้อยกว่าในวันนี้
ซึ่งตรงข้ามกับที่คนอ่านจะเดา

### 4. harness จัดการสอง server ได้ดี — แต่มี status ตัวหนึ่งที่ชวนเข้าใจผิด

TrueForge 0.1.4 ต่อได้ทั้งสองฝั่ง, redact header secret ในทุก response ของ API, ทำ DCR + PKCE S256
เองครบ และส่งต่อ 403 ของฮับออกมาตรง ๆ ไม่กลืน

แต่ connector ที่ถือ credential ซึ่ง upstream ปฏิเสธ ยังรายงาน `auth_status: authenticated`
ฟิลด์นี้ติดตามว่า *"มี credential ผูกอยู่"* ไม่ใช่ *"credential ใช้ได้"* — ใครจะทำหน้า health
อย่าอิงฟิลด์นี้

### 5. TrueForge ไม่ใช่ gateway และ gateway ไม่ใช่ TrueForge

harness ต่อไปยัง MCP server แต่ไม่เคยเสิร์ฟ MCP เอง · API ของมันมี 47 เส้นและไม่มีเส้นไหนพูด
โปรโตคอล MCP — `/api/v1/mcp-servers*` เอาไว้จัดการ connector · ในแพ็กเกจฝั่ง server ไม่มี
`StreamableHTTPServerTransport` หรือ `new McpServer()` ตัว MCP server ที่มันสร้างถูกส่งเข้า
sandbox ของ agent · และการเรียก tool เกิดใน agent turn เท่านั้นซึ่งต้องมี model provider
gateway ที่สร้างบนมันจึงต้องจ่ายค่า LLM หนึ่งรอบต่อการอ่านหนึ่งครั้ง

ตัว gateway เป็น installation แยกต่างหากใน control plane ของ TrueFoundry
(`listGatewayInstallations` → `resolveDefaultGatewayUrl`) ซึ่งคือสิ่งที่รอบ 2 ใช้

### 6. OAuth ของ gateway เข้ากติกา PKCE ของฮับไม่ได้

ฮับบังคับ PKCE เว้นแต่ผู้เรียกเป็น *publicish*
(`publicish = isPublicClient(clientId) || isTrustedRedirectUri(redirectUri)`, `app.ts:362`)
โฮสต์ redirect ของ gateway ไม่อยู่ในรายชื่อที่ฮับเชื่อถือ — เป็น allowlist สั้น ๆ ของโฮสต์ผู้ให้บริการ AI
บวก loopback ซึ่งมีไว้ให้ client ที่ทำ PKCE ไม่ได้ยังต่อได้ — และ gateway ก็ไม่ส่ง `code_challenge`
ทางหนีมีสองทางและตันทั้งคู่ โดยจำลองซ้ำกับ sandbox ด้วยโค้ด upstream ที่ไม่แก้อะไร:

| การตั้งค่า connector | ผล |
| --- | --- |
| DCR (`registration_url`) + redirect ของ gateway + ไม่มี PKCE | `400` "ไคลเอนต์ต้องส่ง code_challenge (PKCE)" |
| public client ที่ฮับ seed ไว้ + redirect ของ gateway + ไม่มี PKCE | `400 invalid_client` — client ตัวนั้นมี `redirectUris: []` และเติมให้เฉพาะโฮสต์ที่ *trusted* |
| public client ตัวเดิม + redirect ที่อยู่ใน allowlist อยู่แล้ว + ไม่มี PKCE | `200` หน้า consent ขึ้นปกติ |

แถวที่สามคือตัวแยกตัวแปร: ต่างกันแค่ชื่อโฮสต์ใน allowlist เท่านั้น · การตั้ง `use_pkce` /
`pkce` / `code_challenge_method` ที่ connector ไม่เปลี่ยนอะไร เพราะ API เก็บฟิลด์ที่ไม่รู้จักไว้เงียบ ๆ
(แม้แต่ `__unknown_probe__` ก็ผ่าน) การที่มันรับค่าจึงไม่ใช่หลักฐานว่ารองรับ

การเติมโฮสต์ของ gateway ลง allowlist นั้นจะปลดทั้งสองด่านพร้อมกัน และเป็นความเชื่อถือระดับเดียวกับ
ที่โฮสต์ผู้ให้บริการ AI ในรายการได้อยู่แล้ว · **แต่ไม่ได้แก้ให้ไซต์ไหนทั้งนั้น** เพราะเป็นการแก้
production และเป็นการยกเว้น PKCE โดยเจตนา จึงเป็นเรื่องของเจ้าของงาน ไม่ใช่ของ PoC

### 7. connector บน gateway วางอยู่บนอะไรจริง ๆ

ทั้งสอง connector ใช้ `auth_data.type: "header"` กับ `auth_level: "global"` · ฝั่ง collaboration
ถือ `Authorization` กับ `X-Client-Name` ส่วน connector ของ IT Ops ถือ `Authorization` ที่เป็น
โทเคนบทบาท IT ของไซต์ · เมื่อดูข้อค้นพบ 2 แล้ว นี่ไม่ใช่ตัวเลือกที่อ่อนกว่า OAuth — มันคือความลับ
ก้อนเดียวกันโดยมีชิ้นส่วนน้อยกว่า

ของที่ค้นเจอระหว่างตั้งค่าและไม่มีในเอกสารสาธารณะ: `auth_data.type` รับเฉพาะ `header`,
`passthrough` และ `oauth2` และ `header` รับ `auth_level` ค่าเดียวคือ `global` ค่าอื่นถูกปฏิเสธ
ด้วยข้อความ `Unsupported header auth_level`

### 8. สิ่งที่ gateway มีไว้ทำ ยังไม่ได้ทดสอบ

ทุก call ที่ผ่าน gateway ในรอบนี้มาจาก principal เดียวที่มีสิทธิ์ทุกที่ ดังนั้นคุณสมบัติที่ว่า
"gateway ปฏิเสธผู้เรียกที่ไม่ควรมาแตะ connector นี้" — ซึ่งเป็นเหตุผลที่ gateway มีค่า และเป็น
ครึ่งของ AC3 ที่ RBAC ของ upstream แทนไม่ได้ — จึงเป็น **NOT RUN**

การปิดข้อนี้ต้องมี principal ที่สองบน TrueFoundry (virtual account หรือ PAT ของผู้ใช้อีกคน)
ที่ไม่มีสิทธิ์บน connector เหล่านี้ · แผน Developer แบบฟรีให้ 3 users จึงไม่มีค่าใช้จ่ายใด ๆ
เหลือแค่การตัดสินใจ

### 9. gateway ปฏิเสธผู้ที่ไม่มีสิทธิ์จริง — ที่ชั้นของมันเอง

principal ที่ใช้คือ virtual account ที่ไม่ผูก role ใด ๆ · PAT ใบที่สองที่ออกจากผู้ใช้คนเดิม
**ใช้เป็น negative test ไม่ได้** เพราะ PAT สืบสิทธิ์จากผู้ใช้ที่ออกมัน permission จึงเท่ากันทุกบรรทัด

| การทดสอบ | ผล |
| --- | --- |
| ไม่มี role binding → connector ทั้งสองและ virtual endpoint | 403 ทั้งสามทาง (owner ได้ 200) |
| ผูก `mcp-server-user` เฉพาะ connector เดียว | connector นั้น 200 · อีกตัว 403 |
| ถอน role binding แล้วยิงซ้ำ | 403 ตั้งแต่ครั้งแรก |
| propagation | ขาให้ ~0 วินาที · ขาถอน ~1 วินาที |

ข้อความที่ปฏิเสธคือของ gateway เอง ระบุทั้งชื่อ principal และชื่อ connector
(`User <principal> is not authorized to access MCP server: <connector>`) คนละก้อนกับ 403 ของ
nginx ฝั่งฮับ (`This token cannot access this MCP path`) จึงแยกชั้นที่ปฏิเสธออกจากกันได้จริง

คำศัพท์ที่ใช้ได้จริงบน tenant นี้: `resourceType: mcp-server` และ role ชื่อ `mcp-server-user`
(ชื่ออื่นที่ลองทั้งหมดตอบ `Role not found`)

### 10. subset ของ tool บน Virtual MCP ไม่ใช่ขอบเขตความปลอดภัย

`servers[].tools` ถูกเก็บลง manifest จริง แต่ endpoint ยังเปิดครบทั้ง 39 tools และเรียก tool ที่
อยู่นอก subset ได้สำเร็จ (ทดสอบด้วย tool อ่านเท่านั้น) ลองอีกสามรูปแบบของฟิลด์กับ server ตัวเดียว
ได้ผลเท่ากันหมดคือเห็นครบทั้ง server

สิ่งที่ใช้ได้จริงคือการประกอบ **ราย server** — virtual server ที่ใส่เฉพาะ collab เปิดแค่ 15 tools

ผลต่อแผน: pilot อ่านอย่างเดียวพึ่ง virtual server อย่างเดียวไม่ได้ ต้องมี enforcement ที่ upstream
และต้องรู้ว่าทั้งสองระบบไม่ได้เป็น read-only โดยธรรมชาติ — collab มี tool เขียนอยู่ใน set เดียวกัน
ส่วน IT role มี `rag_reindex` / `rag_run_ocr` / `pstack_call_tool` ที่เขียนได้

ยังไม่สรุปว่า TrueFoundry ทำไม่ได้ อาจเป็นชื่อฟิลด์อื่นหรือฟีเจอร์ของแผนที่สูงกว่า ต้องยืนยันก่อน
วางแผนบนสมมติฐานนี้

### 11. ช่องว่างที่บันทึกไว้ ยังไม่ปิดโดยตั้งใจ

**per-denied-call audit ที่ฝั่งฮับ** — เส้นทางอ่านอย่างเดียวบันทึกนโยบายของตัวเองตอน boot และ
ผู้เรียกได้คำปฏิเสธที่ระบุชื่อ tool แต่ฝั่ง server ยังไม่มีบรรทัด log ต่อการเรียกที่ถูกปฏิเสธหนึ่งครั้ง
การเพิ่มต้องมี hook ที่ชั้น HTTP ซึ่งอยู่ใน `mcp-common` ที่ทุกบริการในฮับใช้ร่วมกัน จึงไม่ทำใน
รอบนี้เพื่อไม่ขยาย blast radius (ตกลงกันไว้ใน dis-bc779b20 seq 22) — บันทึกเป็น follow-up

## Go / No-go สำหรับรอบ 3

**Go** สำหรับการใช้งานภายในทีมบนเส้นทางใดก็ได้: ทางตรงสำหรับสิ่งที่รันอยู่ในเครือข่ายออฟฟิศ
และ gateway สำหรับสิ่งที่ควรเข้าถึงทั้งสองระบบผ่านประตูเดียวด้วย credential ขาเข้าชุดเดียว

**No-go** สำหรับอะไรก็ตามที่พึ่งการอนุญาตรายผู้เรียก การเพิกถอนรายตัว หรือความน่าเชื่อถือของ
authorship ในโต๊ะ จนกว่า:

1. ~~ข้อค้นพบ 8~~ ปิดแล้วด้วยข้อค้นพบ 9 — gateway บังคับสิทธิ์ได้จริง · แต่ข้อค้นพบ 10 เปิด
   คำถามใหม่แทน: การกรองราย tool ยังไม่มี enforcement
2. ข้อค้นพบ 1 ถูกตัดสิน — จะผูก identity กับโทเคน หรือประกาศว่า authorship ในโต๊ะเป็นข้อมูลประกอบ
3. เจ้าของงานตัดสินข้อค้นพบ 6 — เติมโฮสต์ของ gateway ลง allowlist แล้วได้ OAuth จริง
   หรืออยู่กับ credential แบบ header แล้วยอมรับว่าเป็นความลับที่ใช้ร่วมกันต่อ connector
4. ฮับมีที่เก็บ OAuth แบบถาวร ถ้าจะให้ OAuth เป็นเส้นทางที่แนะนำ (ข้อค้นพบ 3)

ที่ยังค้างจากรอบ 1: deployment ทดสอบของ collaboration (ปลด OAuth และการทดสอบเขียนของ collab)
และ credential ของ model provider (ทำให้ครึ่ง harness ของ AC2 เป็น PASS)

**หมายเหตุเรื่องเส้นทางข้อมูล สำหรับคนที่ต้องเซ็นอนุมัติ:** บนเส้นทาง gateway ทราฟฟิกของ tool call
ทั้งสองระบบวิ่งผ่านคลาวด์ของ TrueFoundry · ทุกอย่างที่วัดในรอบนี้เป็นข้อมูล fixture — RAG ของ
ฮับไซต์รายงาน `backend=fixture sample=true` — จึงไม่มีข้อมูลไซต์ออกจากเครือข่ายระหว่าง PoC
การชี้ gateway ไปที่ฮับที่มีข้อมูลไซต์จริงเป็นการตัดสินใจคนละใบ
