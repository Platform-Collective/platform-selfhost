#!/usr/bin/env python3
"""
Apply the kind of changes people make to an upstream huly-selfhost checkout, so that
migrate-from-huly.sh can be tested against them. Used by the unit tests and by the
end-to-end CI job (which really runs the result, so everything here must work).

  - a mail service (sending to a mailpit container) and the mailpit container itself
  - an extra environment variable on transactor, and a resource limit
  - a variable for the mail service in huly_v7.conf (not part of the template)
  - .huly.nginx: a bigger upload limit and a location of your own (/_mailpit), and
    nginx made to start after mailpit (a static proxy_pass needs the host at startup)
  - upstream's broken redpanda and minio healthchecks fixed the way this repository fixed
    them (as anyone running a health check had to); identical to ours, so nothing is
    carried over for them

Usage: customize_huly.py HULY_DIR
"""
import re
import sys


def main(huly_dir: str) -> None:
    compose_path = f"{huly_dir}/compose.yml"
    compose = open(compose_path).read()
    extra_services = """  mail:
    image: hardcoreeng/mail:${HULY_VERSION}
    environment:
      - PORT=8097
      - SOURCE=noreply@example.com
      - SMTP_HOST=mailpit
      - SMTP_PORT=1025
      - SMTP_USERNAME=noreply
      - SMTP_PASSWORD=${SMTP_PASSWORD}
    restart: unless-stopped
    networks:
      - huly_net

  mailpit:
    image: axllent/mailpit:v1.21
    restart: unless-stopped
    networks:
      - huly_net

"""
    compose = compose.replace("  rekoni:\n", extra_services + "  rekoni:\n", 1)
    compose = compose.replace(
        '    image: "nginx:1.21.3"\n',
        '    image: "nginx:1.21.3"\n    depends_on:\n      - mailpit\n', 1)
    compose = compose.replace(
        "    image: hardcoreeng/transactor:${HULY_VERSION}\n",
        "    image: hardcoreeng/transactor:${HULY_VERSION}\n    mem_limit: 4g\n", 1)
    compose = compose.replace(
        "      - FULLTEXT_URL=http://fulltext:4700\n",
        "      - FULLTEXT_URL=http://fulltext:4700\n      - MIGRATION_TEST_FLAG=kept\n", 1)
    compose = compose.replace(
        "test: ['CMD', 'rpk', 'cluster', 'info', '-X', 'user=${REDPANDA_ADMIN_USER}', '-X', 'pass=${REDPANDA_ADMIN_PWD}']",
        "test: ['CMD', 'rpk', 'cluster', 'info']", 1)
    compose = compose.replace("test: ['CMD', 'mc', 'ready', 'local']", "test: ['CMD', 'silo', 'healthcheck', 'ready']", 1)
    assert "'mc', 'ready'" not in compose and "pass=${REDPANDA_ADMIN_PWD}" not in compose
    assert "depends_on:\n      - mailpit" in compose and "mailpit" in compose and "MIGRATION_TEST_FLAG" in compose and "mem_limit" in compose
    open(compose_path, "w").write(compose)

    # upstream setup.sh rewrites huly_v7.conf from its template, so variables of your own
    # are appended after setup has run - the same thing users do by hand
    with open(f"{huly_dir}/huly_v7.conf", "a") as f:
        f.write("SMTP_PASSWORD=mailpit-accepts-anything\n")

    nginx_path = f"{huly_dir}/.huly.nginx"
    nginx = open(nginx_path).read()
    nginx = nginx.replace("client_max_body_size 100M;", "client_max_body_size 1G;", 1)
    nginx = re.sub(r"\n}\s*$", """

    location /_mailpit/ {
        proxy_set_header Host $host;
        proxy_pass http://mailpit:8025/;
    }
}
""", nginx)
    assert "1G" in nginx and "/_mailpit/" in nginx
    open(nginx_path, "w").write(nginx)


if __name__ == "__main__":
    main(sys.argv[1])
