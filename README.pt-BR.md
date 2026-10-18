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
| [pg-throughput-per-connection](skills/pg-throughput-per-connection/SKILL.md) | Tirar mais vazão de cada conexão, conexões demais, lentidão sob carga, espera por locks, escalar sem instância maior: um comando por requisição, commit antes de trabalho fora do banco, filas com SKIP LOCKED, contadores quentes particionados, pool pequeno e medido |

### Fluxos: o seu banco, só leitura

| Fluxo | O que você recebe |
|---|---|
| [db-audit](skills/db-audit/SKILL.md) | Um diagnóstico somente leitura do seu PostgreSQL ou MySQL: queries mais caras, cache hit, índices sem uso, duplicados e faltando, atraso de vacuum ou purge, transações longas, esperas por lock e conexões, ordenados por impacto, com migrations e rollbacks |
| [db-explain](skills/db-explain/SKILL.md) | O plano de um SELECT lento explicado em palavras simples, e o índice ou a reescrita que resolve, como migration; EXPLAIN ANALYZE só com o seu consentimento |
| [db-connection-budget](skills/db-connection-budget/SKILL.md) | Quantas conexões a sua frota abre no pior momento (autoscaling mais o pico do deploy) contra o que o banco permite, com tamanhos de pool e limites por role |

### MySQL (v1.1)

| Skill | Use quando |
|---|---|
| [mysql-keys-and-types](skills/mysql-keys-and-types/SKILL.md) | Escolher chaves primárias e tipos de coluna no InnoDB: BIGINT AUTO_INCREMENT ou UUID em BINARY(16), utf8mb4, DATETIME ou TIMESTAMP, DECIMAL para dinheiro, strict mode, NOT NULL, CHECK e foreign keys, JSON |
| [mysql-indexing](skills/mysql-indexing/SKILL.md) | Criar, revisar ou remover índices InnoDB, ou quando o EXPLAIN mostra type ALL, Using filesort ou index_merge inesperados |
| [mysql-query-patterns](skills/mysql-query-patterns/SKILL.md) | Carregar uma página com seus filhos, paginar (keyset escrito por extenso, sem row constructor), inserir em lote, upsert com o alias AS, colunas nomeadas, EXPLAIN ANALYZE seguro |
| [mysql-transactions-and-locking](skills/mysql-transactions-and-locking/SKILL.md) | Abrir transações InnoDB, REPEATABLE READ ou READ COMMITTED e gap locks, filas com SKIP LOCKED, NOWAIT, lock wait timeout (1205) e deadlock (1213) |
| [mysql-online-ddl](skills/mysql-online-ddl/SKILL.md) | Alterar o schema com tráfego ativo: ALGORITHM e LOCK explícitos, limite de versões de linha do INSTANT, metadata locks com lock_wait_timeout, índices invisíveis antes do drop, gh-ost |
| [mysql-connections](skills/mysql-connections/SKILL.md) | Dimensionar os pools de conexão da frota: orçamento, pico do deploy, MAX_USER_CONNECTIONS por conta, wait_timeout contra o tempo de vida do pool, pinning do RDS Proxy |

---

## Mais volume, menos conexões, sem esperar lock

As mesmas quatro requisições de API escritas do jeito comum e do jeito que estas skills ensinam, medidas com `pgbench` contra um PostgreSQL 17 limitado a 2 vCPU e 1 GiB (um RDS db.t4g.micro) com 0,5 ms de latência de rede ([`benchmarks/throughput/`](benchmarks/throughput/)):

| Requisição | Jeito comum, melhor caso | Com as skills, 4 conexões | Com as skills, melhor caso | Latência |
|---|---|---|---|---|
| Página de pedidos com itens | 2.179 req/s (16 conexões) | **5.893 req/s** | **15.047 req/s (6,9×)** | 6,9 ms → **0,68 ms** |
| Criar um pedido com itens | 3.279 req/s (16) | 2.405 req/s | **8.464 req/s (2,6×)** | 4,3 ms → **1,7 ms** |
| Pegar um job da fila | ~335 req/s com qualquer pool, 40 de 64 sessões esperando lock | **1.656 req/s** | **4.994 req/s (15×)**, sem espera por lock | 47 ms → **3,2 ms** |
| Decrementar um contador quente | 1.671 req/s, pior com mais conexões | **2.372 req/s** | **6.681 req/s (4×)** | 11 ms → **2,4 ms** |

Com 4 conexões, a página em um comando atende 3,2 vezes o que a página com N+1 atende com 64. Nesta instância, 64 conexões renderam menos que 16 em todos os casos: um pool pequeno com conexões seguradas por pouco tempo vence um pool grande. As regras estão em [pg-throughput-per-connection](skills/pg-throughput-per-connection/SKILL.md).

---

## Muda o que os agentes escrevem?

Medido com `claude plugin eval` ([`evals/`](evals/)): cada tarefa roda com e sem o plugin, 3 vezes por lado, e graders por regex conferem o arquivo SQL que o agente escreve. Outubro de 2026.

| | Sem plugin | Com plugin |
|---|---|---|
| 8 tarefas de base (índice online, FK, NOT NULL, paginação nos dois bancos, coluna INSTANT no MySQL, chave UUID, fila de jobs) | 24 / 24 | **24 / 24** |
| 9 tarefas com armadilhas conhecidas | 23 / 27 | **27 / 27** |
| **Todas as 51 execuções** | **47 / 51 (92%)** | **51 / 51 (100%)** |

Onde o agente errou sem o plugin:

| Tarefa | Sem | Com | A falha |
|---|---|---|---|
| Procedure de transferência no MySQL | 1 / 3 | **3 / 3** | Sem retry da transação inteira no deadlock 1213, então uma transferência concorrente perde dinheiro |
| Job único atrás do PgBouncer | 1 / 3 | **3 / 3** | `pg_advisory_lock` de sessão atrás de pooling por transação, então o job "único" roda duas vezes |

**Auditando um banco real.** O [`benchmarks/audit-fixture/`](benchmarks/audit-fixture/) monta um PostgreSQL 17 com dez problemas plantados (foreign key sem índice, índices duplicado e sem uso, paginação com OFFSET, N+1, uma sessão idle in transaction, autovacuum desligado com linhas mortas, frota acima do orçamento de conexões, `work_mem` global perigoso, chaves UUID aleatórias), roda tráfego e exporta as views padrão de estatística. O agente lê a exportação e escreve um relatório e uma migration; um juiz por problema mais checagens de segurança no SQL (CONCURRENTLY, sem VACUUM FULL, sem apagar chave primária).

| | Sem plugin | Com plugin |
|---|---|---|
| Execuções que acharam os dez problemas e escreveram uma migration segura | 1 / 3 | **3 / 3** |
| Checagens cumpridas | 45 / 48 | **48 / 48** |

Sem o plugin, o agente deixou passar a paginação com OFFSET, a query mais cara da exportação, em 2 de 3 execuções, e o `work_mem` global em 1.

O modelo já conhece a maioria das regras de livro; o plugin faz ele acertar sempre e fecha as brechas que causam incidente em produção. Uma rodada anterior, antes de as descrições das skills trazerem a regra principal e as palavras do usuário ("infinite scroll", "next page"), não mostrou diferença e teve uma skill que nunca carregou; por isso toda descrição agora começa pela tarefa e pela regra mais importante.

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
