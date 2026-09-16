# Dual MCP PoC — runbook

ทำซ้ำผลทุกข้อใน `dual-mcp-results.md` ได้จากเครื่องเปล่า ไม่มีขั้นตอนไหนแตะ deployment ของไซต์
credential ของ production หรือ tool ที่มีสิทธิ์พิเศษ

## 0. ของที่ต้องมีก่อน

`docker`, `docker compose`, `node` 22.14 ขึ้นไป, `curl`, `jq`, `openssl`, `python3`

```bash
git clone https://github.com/monthop-gmail/itops-mcp-hub vendor/itops-mcp-hub   # pin: da63143
cp .env.example .env    # แล้วเติมค่า COLLAB_* ของ deployment ที่จะใช้
```

## 1. sandbox ของ IT Ops

```bash
cd vendor/itops-mcp-hub
cp .env.example .env
# โทเคนสามใบต้องคนละค่า และเป็นของ sandbox เท่านั้น — ห้ามคัดลอกโทเคนของไซต์มาใส่
for k in IT_TOKEN ADMIN_TOKEN ACCOUNTING_TOKEN; do
  sed -i "s|^${k}=.*|${k}=$(openssl rand -hex 32)|" .env
done
sed -i 's|^MCP_LAN_PORT=.*|MCP_LAN_PORT=19080|;
        s|^PUBLIC_MCP_ORIGIN=.*|PUBLIC_MCP_ORIGIN=http://127.0.0.1:19080|;
        s|^PUBLIC_MCP_HOSTNAME=.*|PUBLIC_MCP_HOSTNAME=127.0.0.1:19080|;
        s|^ZABBIX_WEB_LAN_PORT=.*|ZABBIX_WEB_LAN_PORT=19443|;
        s|^ZABBIX_SERVER_LAN_PORT=.*|ZABBIX_SERVER_LAN_PORT=19051|;
        s|^MESHCENTRAL_HTTPS_PORT=.*|MESHCENTRAL_HTTPS_PORT=19444|;
        s|^MESHCENTRAL_AGENT_PORT=.*|MESHCENTRAL_AGENT_PORT=14433|' .env
chmod 600 .env

# --no-deps กัน Zabbix, MeshCentral, ฮับบัญชี และ tunnel ไม่ให้ขึ้นมาด้วย
docker compose -p itops-poc build sub-mcp-zabbix mcp-hub-it nginx mcp-oauth
docker compose -p itops-poc up -d --no-deps \
  sub-mcp-zabbix sub-mcp-meshcentral sub-mcp-rag sub-mcp-zktime sub-mcp-pstack \
  mcp-hub-it mcp-hub-admin mcp-oauth nginx
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:19080/healthz   # ต้องได้ 200
```

## 2. TrueForge harness (standalone, SQLite, ไม่ต้องมี infra)

```bash
mkdir -p .local/trueforge-data
SQLITE_PATH="$PWD/.local/trueforge-data/trueforge.db" PORT=8790 \
  PUBLIC_BASE_URL=http://localhost:8790 \
  npx -y @truefoundry/trueforge@latest    # รุ่นที่ใช้: 0.1.4
```

สองเรื่องที่ถ้าไม่รู้จะเสียเวลา:

- มัน bind เฉพาะ **IPv6 loopback** · `http://localhost:8790` ใช้ได้ แต่ `http://127.0.0.1:8790` ไม่ได้
- `PUBLIC_BASE_URL` ต้องสะกดให้ตรงกัน ไม่อย่างนั้น callback ของ OAuth ที่มันส่งให้ MCP server
  จะชี้ไปที่ที่เบราว์เซอร์เข้าไม่ถึง

## 3. รัน probe ฝั่งทางตรง

```bash
set -a; . vendor/itops-mcp-hub/.env; . ./.env; set +a
export ITOPS_BASE_URL=http://127.0.0.1:19080 ITOPS_IT_TOKEN="$IT_TOKEN"

./scripts/smoke-bearer.sh                      # ทางตรงไม่ผ่าน harness: สอง server + negative auth
ITOPS_RUN_FLOW=1 ./scripts/probe-oauth.sh      # discovery ทั้งสองฝั่ง; code flow เต็มรูปแบบบน sandbox
ITOPS_RUN_FLOW=1 ./scripts/probe-trueforge.sh  # ให้ harness เป็นคนต่อสอง server เอง
```

`ITOPS_RUN_FLOW=1` จะไปลงทะเบียน OAuth client บนเป้าหมาย ตั้งเฉพาะกับ sandbox ของตัวเองเท่านั้น ·
ถ้าจะรันขา consent ซ้ำหลัง connector ถือโทเคนไปแล้ว ให้ตั้งชื่อใหม่:
`ITOPS_OAUTH_SERVER_NAME=itops-it-oauth-run3`

## 4. เส้นทาง gateway (topology B)

ต้องมี tenant ของ TrueFoundry แผน Developer แบบฟรีก็พอ — PoC นี้ใช้แผนนั้น

```bash
cat >> .env.tfy <<'ENV'
TRUEFOUNDRY_SERVICEFOUNDRY_SERVER_URL=https://<tenant>.truefoundry.cloud/api/svc
TRUEFOUNDRY_API_KEY=<personal access token>
ENV
chmod 600 .env.tfy
```

ลงทะเบียนหนึ่ง connector ต่อหนึ่ง server · `auth_data.type` รับแค่ `header`, `passthrough` และ
`oauth2` ส่วน `header` รับ `auth_level` ค่าเดียวคือ `global`:

```bash
set -a; . ./.env.tfy; set +a
S="$TRUEFOUNDRY_SERVICEFOUNDRY_SERVER_URL"

# collaboration — header X-Client-Name คือสิ่งที่ workspace บันทึกเป็นชื่อผู้เขียน
jq -n --arg tok "Bearer $COLLAB_TOKEN" '{manifest:{type:"mcp-server/remote",
  name:"ai-collaboration-mcp",description:"Shared AI collaboration workspace.",
  url:"https://<collab-host>/mcp",
  auth_data:{type:"header",auth_level:"global",
    headers:{"Authorization":$tok,"X-Client-Name":"monthop-gmail/trueforge"}}}}' \
| curl -sS -X PUT "$S/v1/mcp" -H "Authorization: Bearer $TRUEFOUNDRY_API_KEY" \
       -H 'content-type: application/json' -d @-

# ฮับ IT Ops ของไซต์ — รูปเดียวกัน ใช้โทเคนบทบาท IT ของไซต์
jq -n --arg tok "Bearer $SITE_IT_TOKEN" '{manifest:{type:"mcp-server/remote",
  name:"<itops-connector>",description:"IT operations hub, IT role, read-only.",
  url:"https://<itops-site-host>/mcp/it/mcp",
  auth_data:{type:"header",auth_level:"global",headers:{"Authorization":$tok}}}}' \
| curl -sS -X PUT "$S/v1/mcp" -H "Authorization: Bearer $TRUEFOUNDRY_API_KEY" \
       -H 'content-type: application/json' -d @-
```

แล้วยิง probe:

```bash
TFY_TENANT=<tenant> TFY_ITOPS_SERVER=<itops-connector> ./scripts/probe-gateway.sh
```

**อย่า**ตั้ง connector เหล่านี้เป็น `oauth2` กับฮับ itops — gateway ไม่ส่ง `code_challenge` และ
โฮสต์ redirect ของมันไม่อยู่ใน allowlist ของฮับ ทั้งแบบ DCR และแบบ seeded public client จึงตันทั้งคู่
ข้อค้นพบ 6 ใน `dual-mcp-results.md` มีขั้นตอนจำลองไว้ครบ

connector ที่เพิ่งสร้างอาจใช้เวลาไม่กี่วินาทีกว่าจะ route ได้ · call แรกอาจตอบ
`MCP server not found for integration ID` ให้ลองซ้ำก่อนไปไล่หาสาเหตุ

## 5. ทางเลือก: การทดลองเรื่อง state ของ OAuth ที่หายตอน restart

```bash
docker compose -p itops-poc restart mcp-oauth
# refresh_token ที่ออกก่อน restart จะตอบ invalid_client หลัง restart
# ขณะที่เส้น static Bearer ตอบ 200 ตลอดช่วงเดียวกัน
```

## 6. เก็บกวาด

```bash
docker compose -p itops-poc down -v          # ลบ sandbox และ volume ของมัน
pkill -f '@truefoundry/trueforge'            # หยุด harness
rm -rf .local/trueforge-data                 # ทิ้ง SQLite และ secret ของ connector ที่มันเก็บไว้
rm -f vendor/itops-mcp-hub/.env
```

ไม่มีอะไรถูกสร้างนอกไดเรกทอรีนี้และนอก compose project `itops-poc` การเก็บกวาดจึงไม่ไปรบกวน
deployment ของไซต์ได้ · ข้อยกเว้นเดียวคือ **workspace ของ collaboration** ซึ่ง probe อ่านมัน และ
รายงาน PoC ถูกโพสต์ลงไป — สองอย่างนั้นเป็นบันทึกใน workspace ไม่ใช่ infrastructure จึงลบด้วย
การแก้กระทู้ ไม่ใช่ด้วยขั้นตอนนี้
