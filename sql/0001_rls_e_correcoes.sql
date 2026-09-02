-- Prepacoin (pp-banco) — RLS + correção das RPCs que já existiam.
--
-- Diagnóstico do que estava na base antes desta migração (tabelas
-- `contas` e `transacoes` já existiam, vazias, com trigger de auditoria
-- ligado; RPCs `banco_abrir_conta`, `banco_transferir`, `fn_gerar_iban`
-- já existiam):
--
--  1. CRÍTICO — `banco_transferir` recebia o IBAN de origem por parâmetro
--     e NUNCA conferia se quem chamou é dono da conta. Sendo SECURITY
--     DEFINER chamável por `authenticated`, qualquer aluno logado
--     esvaziava a conta de qualquer empresa. Regra da casa: a identidade
--     vem de `auth.uid()`, nunca de parâmetro.
--  2. RLS estava ligado nas duas tabelas com ZERO policies — ninguém lia
--     nada pelo frontend.
--  3. Falência era marcada em QUALQUER tentativa sem saldo (um erro de
--     digitação do aluno já falia a empresa). Decisão do Germano
--     (2026-09-02): só marca incumprimento quando a transferência
--     recusada é de uma obrigação (salário/imposto/renda/utilities).
--  4. Transferência acima do limite ficava `pendente` sem reservar nada,
--     dava para empilhar pendentes que somadas passavam do saldo.
--  5. Nenhuma das RPCs tinha `exception when others` — erro cru vazava
--     para o browser (viola a pp-base).
--  6. `fn_gerar_iban` usava `hashtext` (int4, ~2 mil milhões de valores)
--     sem checar colisão; colidir estourava a unique constraint como
--     erro cru.
--  7. Não existia RPC de aprovar/rejeitar — o fluxo limite→aprovação
--     estava pela metade.
--
-- Aplicada ao Supabase do projeto (moxxbehwylcjaqjacmyh) em 2026-09-02.

-- ---------------------------------------------------------------------
-- Helpers SECURITY DEFINER — evitam recursão de RLS (lição do classcard
-- e do subsight: policy que consulta outra tabela protegida gera 42P17).
-- ---------------------------------------------------------------------
create or replace function public.fn_minha_cedula()
returns text
language sql
security definer
stable
set search_path = public
as $$
  select p.cedula from public.pessoas p where p.id = auth.uid();
$$;

create or replace function public.fn_minha_empresa_cedula()
returns text
language sql
security definer
stable
set search_path = public
as $$
  select e.cedula
  from public.pessoas p
  join public.empresas e on e.id = p.empresa_id
  where p.id = auth.uid();
$$;

-- true quando o IBAN é de uma conta que o utilizador logado controla
-- (a própria conta, ou a conta da empresa a que está vinculado).
create or replace function public.fn_iban_meu(p_iban text)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select exists (
    select 1 from public.contas c
    where c.iban = p_iban
      and c.cedula in (public.fn_minha_cedula(), public.fn_minha_empresa_cedula())
  );
$$;

-- ---------------------------------------------------------------------
-- RLS: leitura própria + professor vê tudo. Escrita só por RPC
-- (as RPCs são SECURITY DEFINER e passam por cima da RLS de propósito).
-- ---------------------------------------------------------------------
drop policy if exists "conta propria e da empresa" on public.contas;
create policy "conta propria e da empresa"
  on public.contas for select
  using (
    cedula in (public.fn_minha_cedula(), public.fn_minha_empresa_cedula())
    or public.fn_e_professor()
  );

drop policy if exists "transacoes das minhas contas" on public.transacoes;
create policy "transacoes das minhas contas"
  on public.transacoes for select
  using (
    public.fn_iban_meu(origem_iban)
    or public.fn_iban_meu(destino_iban)
    or public.fn_e_professor()
  );

-- ---------------------------------------------------------------------
-- fn_gerar_iban: PT50 + 21 dígitos aleatórios, com garantia de unicidade
-- (o hashtext antigo era int4 e não checava colisão).
-- ---------------------------------------------------------------------
create or replace function public.fn_gerar_iban(p_cedula text default null)
returns text
language plpgsql
security definer
set search_path = public
as $$
declare
  v_iban text;
  v_tentativa int := 0;
begin
  loop
    v_tentativa := v_tentativa + 1;
    v_iban := 'PT50'
      || lpad((floor(random() * 1000000000))::bigint::text, 9, '0')
      || lpad((floor(random() * 1000000000000))::bigint::text, 12, '0');
    exit when not exists (select 1 from public.contas where iban = v_iban);
    if v_tentativa >= 20 then
      raise exception 'Não foi possível gerar um IBAN único.';
    end if;
  end loop;
  return v_iban;
end;
$$;

-- ---------------------------------------------------------------------
-- banco_abrir_conta: idempotente, e só o professor ou o próprio dono
-- da cédula pode abrir. Antes qualquer um abria conta para qualquer um.
-- ---------------------------------------------------------------------
create or replace function public.banco_abrir_conta(
  p_cedula text,
  p_limite bigint default 100000
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_existe text;
  v_iban text;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'erro', 'Sem sessão.');
  end if;
  if p_cedula is null or btrim(p_cedula) = '' then
    return jsonb_build_object('ok', false, 'erro', 'Cédula obrigatória.');
  end if;

  if not (
    public.fn_e_professor()
    or p_cedula = public.fn_minha_cedula()
    or p_cedula = public.fn_minha_empresa_cedula()
  ) then
    return jsonb_build_object('ok', false, 'erro',
      'Só o professor, o próprio titular ou alguém da empresa pode abrir esta conta.');
  end if;

  select iban into v_existe from public.contas where cedula = p_cedula;
  if v_existe is not null then
    return jsonb_build_object('ok', true, 'dados', jsonb_build_object('iban', v_existe, 'nova', false));
  end if;

  if not (public.id_resolver(p_cedula)->>'ok')::boolean then
    return jsonb_build_object('ok', false, 'erro', 'Cédula inexistente: ' || p_cedula);
  end if;

  v_iban := public.fn_gerar_iban(p_cedula);
  insert into public.contas(cedula, iban, limite_aprovacao)
  values (p_cedula, v_iban, coalesce(p_limite, 100000));

  return jsonb_build_object('ok', true, 'dados', jsonb_build_object('iban', v_iban, 'nova', true));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Falha ao abrir conta: ' || sqlerrm);
end;
$$;

-- ---------------------------------------------------------------------
-- banco_transferir: agora confere quem está a chamar, considera o saldo
-- já comprometido por pendentes, e só marca incumprimento em obrigações.
-- ---------------------------------------------------------------------
create or replace function public.banco_transferir(
  p_origem text,
  p_destino text,
  p_valor bigint,
  p_categoria text,
  p_descricao text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_conta record;
  v_id uuid := gen_random_uuid();
  v_codigo text;
  v_pendentes bigint;
  v_disponivel bigint;
  v_obrigacao boolean;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'erro', 'Sem sessão.');
  end if;
  if p_valor is null or p_valor <= 0 then
    return jsonb_build_object('ok', false, 'erro', 'Valor tem de ser positivo.');
  end if;
  if p_origem = p_destino then
    return jsonb_build_object('ok', false, 'erro', 'Origem e destino são a mesma conta.');
  end if;

  select * into v_conta from public.contas
    where iban = p_origem and estado = 'ativa' for update;
  if not found then
    return jsonb_build_object('ok', false, 'erro', 'Conta de origem inexistente ou bloqueada.');
  end if;

  -- a identidade vem da sessão, nunca do parâmetro
  if v_conta.cedula not in (public.fn_minha_cedula(), public.fn_minha_empresa_cedula()) then
    return jsonb_build_object('ok', false, 'erro', 'Esta conta não é sua.');
  end if;

  if not exists (select 1 from public.contas where iban = p_destino and estado = 'ativa') then
    return jsonb_build_object('ok', false, 'erro', 'Conta de destino inexistente.');
  end if;

  -- saldo disponível desconta o que já está preso em transferências pendentes
  select coalesce(sum(valor), 0) into v_pendentes
    from public.transacoes where origem_iban = p_origem and estado = 'pendente';
  v_disponivel := v_conta.saldo - v_pendentes;

  if v_disponivel < p_valor then
    v_obrigacao := coalesce(p_categoria, '') in ('salario', 'imposto', 'renda', 'utilities');

    insert into public.transacoes(id, origem_iban, destino_iban, valor, categoria, descricao, estado)
    values (v_id, p_origem, p_destino, p_valor, p_categoria, p_descricao, 'rejeitada');

    if v_obrigacao and v_conta.cedula like 'EP-%' then
      update public.empresas set estado = 'incumprimento'
        where cedula = v_conta.cedula and estado <> 'falida';
      return jsonb_build_object('ok', false, 'erro',
        'Saldo insuficiente para uma obrigação. Empresa marcada em incumprimento.');
    end if;

    return jsonb_build_object('ok', false, 'erro',
      format('Saldo insuficiente (disponível: %s cêntimos).', v_disponivel));
  end if;

  if p_valor > coalesce(v_conta.limite_aprovacao, 9223372036854775807) then
    insert into public.transacoes(id, origem_iban, destino_iban, valor, categoria, descricao, estado)
    values (v_id, p_origem, p_destino, p_valor, p_categoria, p_descricao, 'pendente');
    return jsonb_build_object('ok', true, 'dados', jsonb_build_object(
      'id', v_id, 'estado', 'pendente',
      'aviso', 'Acima do limite: aguarda aprovação de um gerente.'));
  end if;

  update public.contas set saldo = saldo - p_valor where iban = p_origem;
  update public.contas set saldo = saldo + p_valor where iban = p_destino;

  v_codigo := upper(left(encode(digest(v_id::text || now()::text, 'sha256'), 'hex'), 12));
  insert into public.transacoes(id, origem_iban, destino_iban, valor, categoria, descricao, estado, codigo_auth)
  values (v_id, p_origem, p_destino, p_valor, p_categoria, p_descricao, 'concluida', v_codigo);

  return jsonb_build_object('ok', true, 'dados', jsonb_build_object(
    'id', v_id, 'estado', 'concluida', 'codigo', v_codigo));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Falha na transferência: ' || sqlerrm);
end;
$$;

-- ---------------------------------------------------------------------
-- banco_decidir_pendente: aprovar/rejeitar transferência acima do limite.
-- Só gerente vinculado à empresa dona da conta de origem.
-- ---------------------------------------------------------------------
create or replace function public.banco_decidir_pendente(
  p_transacao_id uuid,
  p_aprovar boolean
)
returns jsonb
language plpgsql
security definer
set search_path = public, extensions
as $$
declare
  v_tx record;
  v_conta record;
  v_pessoa record;
  v_codigo text;
  v_pendentes_antes bigint;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'erro', 'Sem sessão.');
  end if;

  select p.cedula, p.papel into v_pessoa from public.pessoas p where p.id = auth.uid();
  if v_pessoa.cedula is null then
    return jsonb_build_object('ok', false, 'erro', 'Sem ficha na Carteirinha.');
  end if;

  select * into v_tx from public.transacoes where id = p_transacao_id for update;
  if not found then
    return jsonb_build_object('ok', false, 'erro', 'Transação não encontrada.');
  end if;
  if v_tx.estado <> 'pendente' then
    return jsonb_build_object('ok', false, 'erro', 'Esta transação já foi decidida.');
  end if;

  select * into v_conta from public.contas where iban = v_tx.origem_iban for update;
  if not found then
    return jsonb_build_object('ok', false, 'erro', 'Conta de origem inexistente.');
  end if;

  if v_conta.cedula <> public.fn_minha_empresa_cedula() or v_pessoa.papel <> 'gerente' then
    return jsonb_build_object('ok', false, 'erro',
      'Só um gerente da empresa dona da conta pode decidir esta transferência.');
  end if;

  if not p_aprovar then
    update public.transacoes
      set estado = 'rejeitada', decidida_por = v_pessoa.cedula
      where id = p_transacao_id;
    return jsonb_build_object('ok', true, 'dados', jsonb_build_object('estado', 'rejeitada'));
  end if;

  -- revalida saldo no momento da aprovação, descontando outras pendentes
  select coalesce(sum(valor), 0) into v_pendentes_antes
    from public.transacoes
    where origem_iban = v_tx.origem_iban and estado = 'pendente' and id <> p_transacao_id;

  if v_conta.saldo - v_pendentes_antes < v_tx.valor then
    return jsonb_build_object('ok', false, 'erro',
      'Saldo insuficiente agora para aprovar esta transferência.');
  end if;

  update public.contas set saldo = saldo - v_tx.valor where iban = v_tx.origem_iban;
  update public.contas set saldo = saldo + v_tx.valor where iban = v_tx.destino_iban;

  v_codigo := upper(left(encode(digest(v_tx.id::text || now()::text, 'sha256'), 'hex'), 12));
  update public.transacoes
    set estado = 'concluida', codigo_auth = v_codigo, decidida_por = v_pessoa.cedula
    where id = p_transacao_id;

  return jsonb_build_object('ok', true, 'dados', jsonb_build_object(
    'estado', 'concluida', 'codigo', v_codigo));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Falha ao decidir: ' || sqlerrm);
end;
$$;

-- ---------------------------------------------------------------------
-- banco_verificar_comprovante: público (sem login), como a verificação
-- do Subsight. Confirma que um código de autenticação corresponde a uma
-- transação real, sem expor mais do que o necessário.
-- ---------------------------------------------------------------------
create or replace function public.banco_verificar_comprovante(p_codigo text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_tx record;
begin
  if p_codigo is null or btrim(p_codigo) = '' then
    return jsonb_build_object('ok', false, 'erro', 'Código obrigatório.');
  end if;

  select t.valor, t.categoria, t.estado, t.criada_em, t.origem_iban, t.destino_iban
    into v_tx
    from public.transacoes t
    where upper(t.codigo_auth) = upper(btrim(p_codigo));

  if not found then
    return jsonb_build_object('ok', false, 'erro', 'Comprovante não encontrado.');
  end if;

  return jsonb_build_object('ok', true, 'dados', jsonb_build_object(
    'valido', v_tx.estado = 'concluida',
    'estado', v_tx.estado,
    'valor', v_tx.valor,
    'categoria', v_tx.categoria,
    'criada_em', v_tx.criada_em,
    -- só os últimos 4 dígitos: confirma sem expor a conta inteira
    'origem_final', right(v_tx.origem_iban, 4),
    'destino_final', right(v_tx.destino_iban, 4)
  ));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Falha ao verificar: ' || sqlerrm);
end;
$$;
