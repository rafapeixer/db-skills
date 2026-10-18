# db-skills

[English](README.md) | **Português**

**Skills opinativas de PostgreSQL e MySQL para agentes de código, mais fluxos somente leitura que auditam o seu próprio banco.**

Agentes de código escrevem SQL que funciona no notebook e cai em produção: uma query por linha, paginação com `OFFSET` sobre milhões de linhas, migration que trava a tabela por minutos, frota que abre mais conexões do que o banco aguenta. O banco costuma ser a maior linha da conta, e é nesses erros que o dinheiro vai embora.

Cada skill trata de **uma decisão**, toma posição e prova com exemplos que **rodam em PostgreSQL e MySQL de verdade no CI**: o exemplo bom confere que o plano usa o índice, o ruim confere a varredura sequencial que ele causa. As skills de fluxo vão além e olham para o **seu** banco, só leitura, e entregam um relatório com as migrations para corrigir.

Funciona com Claude Code, Cursor, Codex e qualquer agente que leia arquivos `SKILL.md`, em qualquer linguagem de aplicação.

---

## Instalação

### Plugin do Claude Code (recomendado)

```
/plugin marketplace add rafapeixer/db-skills
/plugin install db-skills@db-skills
```

As skills de decisão carregam sozinhas quando a tarefa corresponde. Os fluxos rodam quando você pede:

```
/db-skills:db-audit
/db-skills:db-explain
/db-skills:db-connection-budget
```

### Outros agentes

```bash
npx skills add rafapeixer/db-skills
```

Ou copie `skills/` para o local de onde o seu agente carrega skills.

---

## Skills

### PostgreSQL (v1)

| Skill | Use quando |
|---|---|
| [pg-keys-and-types](skills/pg-keys-and-types/SKILL.md) | Escolher chaves primárias e tipos de coluna: bigint identity, uuidv7 (PG 18+), timestamptz, text com CHECK, numeric para dinheiro, NOT NULL, constraints CHECK e FK, jsonb só para dados sem esquema |
| [pg-indexing](skills/pg-indexing/SKILL.md) | Decidir quais índices criar e remover: ordem das colunas compostas, INCLUDE para cobertura, índices parciais e de expressão, índices em chaves estrangeiras, duplicados e sem uso, skip scan (PG 18+) |
| [pg-query-patterns](skills/pg-query-patterns/SKILL.md) | Desenhar as queries: uma instrução por página com LEFT JOIN LATERAL em vez de N+1, keyset em vez de OFFSET, escritas em lote com unnest ou COPY, upserts com ON CONFLICT, RETURNING, colunas nomeadas |
| [pg-transactions-and-locking](skills/pg-transactions-and-locking/SKILL.md) | Delimitar transações e locks: transações curtas, isolamento com retry da transação inteira em 40001, filas com SKIP LOCKED, NOWAIT e lock_timeout, timeouts por role, advisory locks atrás de poolers |
| [pg-online-migrations](skills/pg-online-migrations/SKILL.md) | Alterar uma tabela em produção sem bloquear: lock_timeout com novas tentativas, o lock de cada ALTER TABLE, defaults constantes, NOT VALID e depois VALIDATE, NOT NULL sem varredura, CREATE INDEX CONCURRENTLY, expand/contract |
| [pg-connections](skills/pg-connections/SKILL.md) | Dimensionar as conexões da frota: orçamento a partir de max_connections menos as reservadas, réplicas × processos × pool incluindo o pico do deploy, CONNECTION LIMIT por role, PgBouncer ou RDS Proxy |
| [pg-observability](skills/pg-observability/SKILL.md) | Descobrir as queries que mais custam: pg_stat_statements por tempo total, track_io_timing, log de queries lentas, auto_explain com amostragem, EXPLAIN ANALYZE seguro, wait events, pg_stat_io, RDS Database Insights |
| [pg-config-by-size](skills/pg-config-by-size/SKILL.md) | Dimensionar shared_buffers, effective_cache_size, work_mem e maintenance_work_mem pela instância, aumentar work_mem para uma única query, parameter groups no RDS e Aurora, I/O assíncrono do PG 18 |
| [pg-vacuum-and-bloat](skills/pg-vacuum-and-bloat/SKILL.md) | Evitar o inchaço das tabelas: autovacuum ajustado por tabela quente, sem sessões longas ou idle in transaction, updates HOT com fillfactor, deletes em lotes, sem VACUUM FULL em tabelas em uso, wraparound de XID |

### Fluxos: o seu banco, só leitura

| Fluxo | O que você recebe |
|---|---|
| [db-audit](skills/db-audit/SKILL.md) | Um diagnóstico somente leitura do seu PostgreSQL ou MySQL: queries mais caras, cache hit, índices sem uso, duplicados e faltando, atraso de vacuum ou purge, transações longas, esperas por lock e conexões, ordenados por impacto, com migrations e rollbacks |
| [db-explain](skills/db-explain/SKILL.md) | O plano de um SELECT lento explicado em palavras simples, e o índice ou a reescrita que resolve, como migration; EXPLAIN ANALYZE só com o seu consentimento |
| [db-connection-budget](skills/db-connection-budget/SKILL.md) | Quantas conexões a sua frota abre no pior momento (autoscaling mais o pico do deploy) contra o que o banco permite, com tamanhos de pool e limites por role |

### Próximas

- **MySQL (v1.1):** chaves e layout do InnoDB, índices, padrões de query, transações e isolamento, DDL online, conexões.

---

## Segurança dos fluxos

Os fluxos conectam no seu banco, então a segurança é garantida pelo banco, não por promessa:

- Eles pedem que você crie um **usuário somente leitura** com timeouts de query e de lock (scripts incluídos). O banco recusa qualquer escrita, mesmo que uma query passe.
- Eles rodam só as queries publicadas em `skills/db-*/queries/`, e o CI confere que nenhuma tem escrita, DDL, comando de manutenção ou `EXPLAIN ANALYZE`.
- Eles nunca aplicam uma correção. Toda mudança volta como arquivo de migration para você revisar.
- O texto das queries aparece com os valores literais escondidos.

---

## Princípios

- **Uma decisão por skill**, com motivo e, quando possível, um número.
- **Só fontes oficiais:** postgresql.org, dev.mysql.com e documentação da AWS. Afirmações de terceiros não entram.
- **Exemplos rodam** em PostgreSQL 15 e 18 e MySQL 8.4 e 9.7 no CI.
- **Online primeiro:** mudanças de schema aparecem do jeito que não bloqueia.
- **Neutro de fornecedor:** PostgreSQL e MySQL puros, com as diferenças de RDS e Aurora apontadas.

---

## Contribuindo

Discorda de uma regra? Abra uma issue com o caso em que ela quebra. Quer adicionar uma skill? Comece pelos [templates/](templates/), siga o [CLAUDE.md](CLAUDE.md), uma skill por PR. Veja o [CONTRIBUTING.pt-BR.md](CONTRIBUTING.pt-BR.md).

---

## Licença

MIT
