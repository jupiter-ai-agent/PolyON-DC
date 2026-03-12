# PolyON DC

PolyON Samba Active Directory Domain Controller.

## 기능
- Samba AD DC 자동 프로비저닝 (`/shared/setup.json` 기반)
- PolyON Operator와 연동 (setup.json 수신 → 도메인 프로비저닝)
- LDAP plain auth 허용 (`ldap server require strong auth = no`)
- Factory reset 지원 (`/shared/.helios-resetting`)

## 환경변수
| 변수 | 기본값 | 설명 |
|------|--------|------|
| `REALM` | `POLYON.DEV` | Kerberos Realm (FQDN 대문자) |
| `DOMAIN` | `POLYON` | NetBIOS 도메인명 |
| `ADMIN_PASSWORD` | `ChangeMe123!` | AD 관리자 비밀번호 |
| `DC_HOSTNAME` | (컨테이너 hostname) | DC 호스트명 |

## 빌드
```bash
docker build --platform linux/amd64,linux/arm64 -t jupitertriangles/polyon-dc:v1.0.0 .
```

## setup.json 형식
```json
{
  "realm": "CMARS.COM",
  "domain": "CMARS",
  "dns_forwarder": "8.8.8.8",
  "dc_admin_password": "YourPassword"
}
```
