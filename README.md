# OathTemplate

Rails starter template with Devise auth, Docker-based local development, and Kamal deployment scaffolding.

## Local setup

1. Copy `template.env` to `.env`.
2. Adjust `.env` if you want different local host ports. `WEB_HOST_PORT` controls the Rails app port and `POSTGRES_HOST_PORT` controls the PostgreSQL port exposed on your machine.
3. Start the local stack with `docker compose up -d db` and `docker compose up --build web`.
4. Prepare the database with `docker compose run --rm web bundle exec rails db:prepare`.

## Template setup checklist

After copying this template for a new app, update the placeholders before deploying:

1. Rename the template values in `config/deploy.yml`.
   Set `service`, `image`, server IPs, registry username, SSH user/key, and the `proxy.hosts` / `APP_HOST` values.
2. Adjust database naming if you change the service name.
   The template defaults use `oath_template` as the PostgreSQL user and `oath_template_production` as the production database prefix in `config/database.yml`, `config/deploy.yml`, and `.kamal/secrets.example`.
3. Copy `.kamal/secrets.example` to `.kamal/secrets`.
4. Generate a new Rails master key and encrypted credentials file.

If you want a completely fresh credentials setup, remove the old files first:

```bash
rm -f config/master.key config/credentials.yml.enc
```

Then run Rails credentials editing. This creates a new `config/master.key` if one does not exist:

```bash
EDITOR=true bin/rails credentials:edit
```

On Windows PowerShell, use:

```powershell
$env:EDITOR = "notepad"
bin/rails credentials:edit
```

After that, copy the generated master key into `.kamal/secrets` as the value of `RAILS_MASTER_KEY`:

```dotenv
RAILS_MASTER_KEY=your-generated-master-key
```

## Manual Kamal secrets setup

You also need a PostgreSQL password and matching database URLs in `.kamal/secrets`.

Generate a password with either of these:

```bash
ruby -rsecurerandom -e "puts SecureRandom.hex(24)"
```

```bash
openssl rand -hex 24
```

Then fill `.kamal/secrets`:
If you changed the service name or database username, keep these values aligned:

1. `config/deploy.yml`
2. `config/database.yml`
3. `.kamal/secrets`

The accessory database host in the template is `oath-template-db`, which is derived from the default Kamal service name `oath-template`.
# Authentication configuration

See [authentication setup](docs/authentication.md) for login methods, provider credentials/callbacks, verified registration, account linking, and security checks.
