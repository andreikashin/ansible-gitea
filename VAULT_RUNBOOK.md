# Vault — ручная инициализация (после `deploy_vault.yml`)

`deploy_vault.yml` ставит Vault и оставляет его **запечатанным (sealed)**. Ниже —
единственный ручной этап: init → сохранить ключи офлайн → распечатать → настроить.
Автоматизировать нельзя намеренно: это момент, где unseal-ключи и root-token
попадают только тебе в руки.

> Плейсхолдеры (подставь свои, НИКОГДА не коммить настоящие значения в этот
> публичный репозиторий): `<VAULT_IP>` — IP ВМ, `<VAULT_FQDN>` — hostname
> (по умолчанию `vault.lan`; не забудь прописать его в локальный DNS-резолвер),
> `<CIUSER>` — cloud-init юзер ВМ (по умолчанию `debian`).

## 0. Доступ к CLI
С любого клиента (или на самой ВМ):

```bash
export VAULT_ADDR="https://<VAULT_FQDN>:8200"
# self-signed серт — забери его с ВМ и укажи как CA:
scp <CIUSER>@<VAULT_IP>:/opt/vault/tls/vault.crt ./vault-ca.crt
export VAULT_CACERT="$PWD/vault-ca.crt"
vault status        # Sealed: true, Initialized: false
```

## 1. Init — СОХРАНИ ВЫВОД ОФЛАЙН
```bash
vault operator init -key-shares=5 -key-threshold=3
```
Выдаст **5 unseal-ключей** и **Initial Root Token**.
- Запиши их **вне Vault и вне репозитория**: менеджер паролей / печать в сейф. Это break-glass.
- В git (тем более публичный) их класть нельзя ни в каком виде.

## 2. Unseal (3 из 5 разных ключей)
```bash
vault operator unseal   # ключ 1
vault operator unseal   # ключ 2
vault operator unseal   # ключ 3
vault status            # Sealed: false
```
> ВАЖНО: после КАЖДОГО рестарта ВМ/сервиса Vault снова запечатан — повтори unseal.

## 3. Логин root
```bash
vault login <initial-root-token>
```

## 4. KV v2 для статических секретов
```bash
vault secrets enable -path=secret kv-v2
```

## 5. Политики (least-privilege)
Читалка секретов инфраструктуры:
```bash
vault policy write infra-ro - <<'EOF'
path "secret/data/infra/*" {
  capabilities = ["read"]
}
EOF
```

## 6. AppRole для машин (коллектор/экспортер, ansible-runner)
```bash
vault auth enable approle
vault write auth/approle/role/infra-reader \
    token_policies="infra-ro" \
    token_ttl=1h token_max_ttl=4h secret_id_ttl=0

vault read  auth/approle/role/infra-reader/role-id          # -> role_id
vault write -f auth/approle/role/infra-reader/secret-id     # -> secret_id
```
`role_id` + `secret_id` кладём на хост-потребитель в защищённый стор
(DPAPI / Windows Credential Manager / PS SecretStore), НЕ в открытый конфиг и НЕ в git.

## 7. Залить секреты (значения — только настоящие, здесь их НЕ пишем)
```bash
vault kv put secret/infra/ilo      username=<ro-user> password=<secret>
vault kv put secret/infra/jumphost username=<user>    password=<secret>
```
> Заведи под мониторинг отдельного **read-only** iLO-юзера (не Administrator) и
> задай сильные пароли — именно они лягут в Vault. Временные заглушки замени.

## 8. Как это читают клиенты
**Ansible** (заменяет `secrets.yml`) — коллекция `community.hashi_vault`:
```yaml
ilo_pw: "{{ lookup('community.hashi_vault.vault_kv2_get',
                    'infra/ilo', engine_mount_point='secret',
                    url='https://<VAULT_FQDN>:8200',
                    auth_method='approle',
                    role_id=vault_role_id, secret_id=vault_secret_id).secret.password }}"
```

**Хост-коллектор (экспортер)** — Vault CLI/API по AppRole:
```bash
export VAULT_ADDR=https://<VAULT_FQDN>:8200 VAULT_CACERT=...vault-ca.crt
TOK=$(vault write -field=token auth/approle/login \
        role_id="$ROLE_ID" secret_id="$SECRET_ID")
VAULT_TOKEN=$TOK vault kv get -field=password secret/infra/ilo
# -> подставляешь в ENV/конфиг экспортера при старте службы
```

## 9. Эксплуатация
- **Бэкап:** `vault operator raft snapshot save vault-$(date +%F).snap` (cron/ansible),
  снапшоты + отдельно unseal-ключи.
- **Рестарт → sealed:** держи 3 unseal-ключа доступными (или позже auto-unseal через
  Transit на втором мини-Vault).
- **Break-glass:** доступ к консоли/iLO/джамп-хосту не должен жить ТОЛЬКО в Vault —
  офлайн-копия критичного всегда должна быть.
- **UI:** `https://<VAULT_FQDN>:8200/ui`.
