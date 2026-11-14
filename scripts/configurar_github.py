#!/usr/bin/env python3
"""
Configura secrets e variáveis do GitHub Actions nos 6 repositórios da Fase 4 (Kc1t/postech-tc4-*).

Requisitos:
  - gh CLI instalado e logado numa conta com ADMIN nos repositórios (gh auth status)
  - aws CLI (para criar o bucket do state do Terraform)
  - Python 3.8+

Uso:
  python3 scripts/configurar_github.py             # configura tudo (pergunta cada valor uma vez)
  python3 scripts/configurar_github.py --status    # só lista o que está cadastrado (nomes, sem valores)
  python3 scripts/configurar_github.py --aws       # só renova as credenciais do Learner Lab
  python3 scripts/configurar_github.py --enable    # liga os deploys (AWS_DEPLOY_ENABLED=true)
  python3 scripts/configurar_github.py --rotate    # gera JWT_SECRET e INTERNAL_API_TOKEN novos

Nenhum valor é passado na linha de comando nem aparece na tela: os segredos são digitados
sem eco e enviados ao gh pela entrada padrão. Deixe em branco (Enter) para pular um item;
o que já está cadastrado continua como está.

Rode no seu terminal, não numa sessão gravada. Equivale ao scripts/setup-github.sh, num
passo só.
"""
import getpass
import json
import os
import secrets
import shutil
import subprocess
import sys
from pathlib import Path

OWNER = os.environ.get("GITHUB_OWNER", "Kc1t")
REGION = os.environ.get("AWS_REGION", "us-east-1")
INFRA = "postech-tc4-infra-k8s"
OS = "postech-tc4-os-service"
BILLING = "postech-tc4-billing-service"
EXECUTION = "postech-tc4-execution-service"
AUTH = "postech-tc4-lambda-auth"
NOTIFIER = "postech-tc4-notification-lambda"

ALL = [INFRA, OS, BILLING, EXECUTION, AUTH, NOTIFIER]
SERVICES = [OS, BILLING, EXECUTION]

EKS_CLUSTER_NAME = "postech-tc4-prod"
SECRETS_DIR = Path(os.environ.get("SECRETS_DIR", Path.home() / ".postech-tc4"))


def gh(args, stdin=None):
    r = subprocess.run(["gh", *args], input=stdin, text=True, capture_output=True)
    if r.returncode != 0:
        print(f"   ERRO: gh {' '.join(args[:3])} ...: {r.stderr.strip()}")
        return False
    return True


def names(kind, repo):
    """Nomes de secrets ou variáveis já cadastrados (kind = 'secret' ou 'variable')."""
    r = subprocess.run(
        ["gh", kind, "list", "-R", f"{OWNER}/{repo}", "--json", "name", "-q", ".[].name"],
        capture_output=True, text=True,
    )
    return set(r.stdout.split())


def set_var(name, value, repos):
    if not value:
        print(f"   --  pulado {name}")
        return
    for repo in repos:
        ok = gh(["variable", "set", name, "-R", f"{OWNER}/{repo}", "-b", value])
        print(f"   {'ok ' if ok else 'X  '} var    {name:28} {repo}")


def set_secret(name, value, repos):
    if not value:
        print(f"   --  pulado {name}")
        return
    for repo in repos:
        ok = gh(["secret", "set", name, "-R", f"{OWNER}/{repo}"], stdin=value)
        print(f"   {'ok ' if ok else 'X  '} secret {name:28} {repo}")


def ask(label, hidden=True):
    prompt = f"   {label} (Enter para pular): "
    return (getpass.getpass(prompt) if hidden else input(prompt)).strip()


def status():
    for repo in ALL:
        print(f"\n== {OWNER}/{repo}")
        print("-- secrets")
        subprocess.run(["gh", "secret", "list", "-R", f"{OWNER}/{repo}"])
        print("-- variables")
        subprocess.run(["gh", "variable", "list", "-R", f"{OWNER}/{repo}"])


def check_prereqs():
    if not shutil.which("gh"):
        sys.exit("gh CLI não encontrado. Instale: https://cli.github.com/")
    if subprocess.run(["gh", "auth", "status"], capture_output=True).returncode != 0:
        sys.exit("gh não está logado. Rode: gh auth login")
    for repo in ALL:
        r = subprocess.run(
            ["gh", "api", f"repos/{OWNER}/{repo}", "--jq", ".permissions.admin"],
            capture_output=True, text=True,
        )
        if r.stdout.strip() != "true":
            sys.exit(f"A conta logada não é admin de {OWNER}/{repo}. Secrets exigem admin.")


def aws(args, env):
    return subprocess.run(["aws", *args, "--region", REGION], capture_output=True, text=True, env=env)


def step_aws():
    """Credenciais do Learner Lab. Devolve o ambiente para o aws CLI (as digitadas ou o perfil padrão)."""
    print("\n[AWS] Credenciais do Learner Lab (AWS Details > Show)")
    key_id = ask("aws_access_key_id")
    secret = ask("aws_secret_access_key")
    token = ask("aws_session_token")
    env = dict(os.environ)
    if key_id and secret and token:
        env.update(AWS_ACCESS_KEY_ID=key_id, AWS_SECRET_ACCESS_KEY=secret, AWS_SESSION_TOKEN=token)
        if aws(["sts", "get-caller-identity"], env).returncode != 0:
            sys.exit("   a AWS recusou essas credenciais (sessão do lab expirada?)")
        set_secret("AWS_ACCESS_KEY_ID", key_id, ALL)
        set_secret("AWS_SECRET_ACCESS_KEY", secret, ALL)
        set_secret("AWS_SESSION_TOKEN", token, ALL)
    elif key_id or secret or token:
        sys.exit("   informe as três credenciais juntas (são temporárias e só valem em conjunto)")
    else:
        print("   --  pulado (o bucket usa as credenciais já configuradas no aws CLI)")
    return env


def step_state(env):
    """Cria o bucket do state (versionado, privado, criptografado) e grava TF_STATE_BUCKET."""
    print("\n[State] Bucket do state do Terraform")
    if not shutil.which("aws"):
        print("   --  aws CLI não encontrado: bucket não criado")
        return
    r = aws(["sts", "get-caller-identity", "--query", "Account", "--output", "text"], env)
    if r.returncode != 0:
        print("   --  sem credenciais válidas da AWS: bucket não criado")
        return
    bucket = f"postech-tc4-tfstate-{r.stdout.strip()}"
    if aws(["s3api", "head-bucket", "--bucket", bucket], env).returncode == 0:
        print(f"   ok  bucket {bucket} já existe")
    else:
        create = ["s3api", "create-bucket", "--bucket", bucket]
        if REGION != "us-east-1":
            create += ["--create-bucket-configuration", f"LocationConstraint={REGION}"]
        steps = [
            create,
            ["s3api", "put-bucket-versioning", "--bucket", bucket,
             "--versioning-configuration", "Status=Enabled"],
            ["s3api", "put-public-access-block", "--bucket", bucket, "--public-access-block-configuration",
             "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"],
            ["s3api", "put-bucket-encryption", "--bucket", bucket, "--server-side-encryption-configuration",
             json.dumps({"Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]})],
        ]
        for args in steps:
            r = aws(args, env)
            if r.returncode != 0:
                sys.exit(f"   ERRO ao criar o bucket: {r.stderr.strip()}")
        print(f"   ok  bucket {bucket} criado (versionado, privado, criptografado)")
    set_secret("TF_STATE_BUCKET", bucket, ALL)


def step_app(rotate):
    """JWT_SECRET e INTERNAL_API_TOKEN são gerados uma vez: trocar invalida os tokens já emitidos."""
    print("\n[App] Segredos da aplicação (gerados, iguais em todos)")
    os_secrets = names("secret", OS)
    for name, repos in (("JWT_SECRET", SERVICES + [AUTH]), ("INTERNAL_API_TOKEN", [OS, AUTH])):
        if rotate or name not in os_secrets:
            set_secret(name, secrets.token_hex(32), repos)
        else:
            print(f"   --  {name} já existe (--rotate para gerar outro)")

    admin = ask("senha do admin da oficina (os-service; Enter para gerar)")
    if not admin:
        if "ADMIN_PASSWORD" in os_secrets:
            print("   --  ADMIN_PASSWORD já existe")
            return
        admin = secrets.token_urlsafe(15)
        SECRETS_DIR.mkdir(mode=0o700, exist_ok=True)
        path = SECRETS_DIR / "admin-password"
        path.write_text(admin + "\n")
        path.chmod(0o600)
        print(f"   ok  senha gerada e salva em {path} (permissão 600)")
    set_secret("ADMIN_PASSWORD", admin, [OS])


def main():
    check_prereqs()
    if "--status" in sys.argv:
        status()
        return
    if "--enable" in sys.argv:
        set_var("AWS_DEPLOY_ENABLED", "true", ALL)
        return
    if "--aws" in sys.argv:
        step_aws()
        return

    print("\n[Variáveis]")
    set_var("AWS_REGION", REGION, ALL)
    set_var("EKS_CLUSTER_NAME", EKS_CLUSTER_NAME, SERVICES)
    set_var("FAULT_INJECTION_ENABLED", "true", SERVICES)
    # "*" libera qualquer origem; para fechar, troque pela lista das origens do front.
    set_var("CORS_ALLOWED_ORIGINS", "*", SERVICES)
    # Os deploys só ligam com --enable, depois de tudo cadastrado.
    if "AWS_DEPLOY_ENABLED" not in names("variable", OS):
        set_var("AWS_DEPLOY_ENABLED", "false", ALL)

    env = step_aws()
    step_state(env)
    step_app("--rotate" in sys.argv)

    print("\n[New Relic]")
    set_secret("NEW_RELIC_LICENSE_KEY", ask("license key (ingestão)"), ALL)
    set_var("NEW_RELIC_ACCOUNT_ID", ask("account id", hidden=False), [INFRA, AUTH, NOTIFIER])
    user_key = ask("user key (NRAK-...)")
    if user_key and not user_key.startswith("NRAK-"):
        sys.exit("   a user key começa com NRAK-")
    set_secret("NEW_RELIC_API_KEY", user_key, [INFRA])
    set_var("NEW_RELIC_ALERT_EMAIL", ask("e-mail dos alertas", hidden=False), [INFRA])

    print("\n[E-mail (Brevo)] notification-lambda")
    set_secret("SMTP_USERNAME", ask("SMTP username"), [NOTIFIER])
    set_secret("SMTP_PASSWORD", ask("SMTP password (chave SMTP do Brevo)"), [NOTIFIER])
    set_var("SMTP_FROM", ask("SMTP from (remetente verificado)", hidden=False), [NOTIFIER])

    print("\n[Mercado Pago] credenciais de TESTE - billing")
    token = ask("MP access token (TEST-... ou APP_USR-...)")
    if token and not token.startswith(("TEST-", "APP_USR-")):
        sys.exit("   não parece um access token do Mercado Pago")
    set_secret("MP_ACCESS_TOKEN", token, [BILLING])
    set_secret("MP_WEBHOOK_SECRET", ask("MP webhook secret (Suas integrações > Webhooks)"), [BILLING])
    # Com mercadopago o billing exige os dois na subida; sem eles, fica no gateway fake.
    billing = names("secret", BILLING)
    gateway = "mercadopago" if {"MP_ACCESS_TOKEN", "MP_WEBHOOK_SECRET"} <= billing else "fake"
    set_var("PAYMENT_GATEWAY", gateway, [BILLING])

    print("\n[URLs] Só existem depois do primeiro deploy (Enter para pular)")
    set_var("API_GATEWAY_URL", ask("URL do API Gateway (billing)", hidden=False), [BILLING])
    set_var("OS_SERVICE_URL", ask("URL do os-service (lambda-auth)", hidden=False), [AUTH])
    set_var("PORTAL_URL", ask("URL do portal (notification-lambda)", hidden=False), [NOTIFIER])

    print("\nPronto. Para conferir: python3 scripts/configurar_github.py --status")
    print("Para ligar os deploys: python3 scripts/configurar_github.py --enable")
    print("As chaves da AWS expiram a cada sessão do Learner Lab: renove com --aws.")


if __name__ == "__main__":
    main()
