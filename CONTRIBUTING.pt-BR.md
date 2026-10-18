# Contribuindo

[English](CONTRIBUTING.md) | **Português**

## Mudando uma regra

1. Abra uma issue: qual regra, o que quebra quando as pessoas a seguem, o que ela deveria dizer e a fonte oficial.
2. Com o acordo feito, um PR atualiza a regra, os exemplos e o checklist juntos.
3. Nunca enfraqueça uma regra para encaixar um exemplo ruim. Corrija o exemplo.

## Adicionando uma skill

1. Skills de decisão se chamam `pg-<decisão>` ou `mysql-<decisão>`; skills de fluxo, `db-<fluxo>`.
2. Comece por [templates/SKILL.template.md](templates/SKILL.template.md) ou [templates/WORKFLOW.template.md](templates/WORKFLOW.template.md).
3. Skills de decisão precisam de `examples/good/test.sql` e `examples/bad/test.sql`. Cada um cria o próprio schema, carrega dados suficientes para planos realistas e confere o resultado com os helpers de `scripts/lib/`.
4. Skills de fluxo guardam toda query em `queries/<engine>/*.sql`, só leitura.
5. Todo fato vem de documentação oficial (postgresql.org, dev.mysql.com, docs.aws.amazon.com) e é citado.
6. Adicione a skill no `README.md` e no `README.pt-BR.md`.

## Verificações locais

Precisa de Docker.

```bash
bash scripts/validate.sh                            # formato, trechos, queries só leitura, índice do README
bash scripts/test-examples.sh                       # todos os exemplos em todas as versões suportadas
ONLY=skills/pg-indexing bash scripts/test-examples.sh   # uma skill
```

## Commits e PRs

- Uma skill por PR, uma mudança lógica por commit: `skill(pg-indexing): add rule on covering indexes`.
- Mudanças em README e CONTRIBUTING atualizam os dois idiomas no mesmo commit.
- Quando conferir ou mudar os fatos de uma skill, coloque essa data em `metadata.verified`.
