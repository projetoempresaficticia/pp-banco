-- Prepacoin (pp-banco) — corrige lógica de três valores (NULL) nas
-- checagens de dono das contas.
--
-- Bug encontrado a testar o 0001/0002 com sessão real: o professor não
-- tem `empresa_id`, logo `fn_minha_empresa_cedula()` devolve NULL. Em
-- SQL, `'EP-2026-00002' not in ('PP-2026-00002', null)` NÃO é `true` —
-- é `null` — e `if null then ... end if` não entra. Resultado: a
-- checagem "esta conta é sua?" era **silenciosamente saltada** para
-- quem não tem empresa. O teste só não moveu dinheiro porque a conta
-- alvo estava a zero; com saldo, a transferência indevida teria passado.
--
-- É exatamente o furo que o 0001 dizia estar a fechar. Lição para as
-- próximas skills: nunca comparar com `in (...)`/`<>` quando um dos
-- lados pode ser NULL — usar `is distinct from`, que devolve sempre
-- true/false.
--
-- Locais corrigidos (todos tinham o mesmo padrão):
--   1. banco_transferir      — dono da conta de origem (o crítico)
--   2. banco_abrir_conta     — quem pode abrir conta para uma cédula
--   3. banco_saldo           — quem pode ler o saldo
--   4. banco_extrato         — quem pode ler o extrato
--   5. banco_decidir_pendente— gerente da empresa dona da conta
--
-- As policies de RLS do 0001 não precisam de correção: dentro de
-- `using (...)`, um resultado NULL é tratado como "não permitido".
-- Aplicada ao Supabase do projeto (moxxbehwylcjaqjacmyh) em 2026-09-02.

-- helper: true só quando a cédula é mesmo controlada por quem está logado
create or replace function public.fn_cedula_minha(p_cedula text)
returns boolean
language sql
security definer
stable
set search_path = public
as $$
  select p_cedula is not null
     and (p_cedula is not distinct from public.fn_minha_cedula()
       or p_cedula is not distinct from public.fn_minha_empresa_cedula());
$$;

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

  if not (public.fn_e_professor() or public.fn_cedula_minha(p_cedula)) then
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

  -- a identidade vem da sessão, nunca do parâmetro (agora à prova de NULL)
  if not public.fn_cedula_minha(v_conta.cedula) then
    return jsonb_build_object('ok', false, 'erro', 'Esta conta não é sua.');
  end if;

  if not exists (select 1 from public.contas where iban = p_destino and estado = 'ativa') then
    return jsonb_build_object('ok', false, 'erro', 'Conta de destino inexistente.');
  end if;

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

  -- à prova de NULL: sem empresa vinculada, nunca é gerente da conta
  if v_conta.cedula is distinct from public.fn_minha_empresa_cedula()
     or coalesce(v_pessoa.papel, '') <> 'gerente' then
    return jsonb_build_object('ok', false, 'erro',
      'Só um gerente da empresa dona da conta pode decidir esta transferência.');
  end if;

  if not p_aprovar then
    update public.transacoes
      set estado = 'rejeitada', decidida_por = v_pessoa.cedula
      where id = p_transacao_id;
    return jsonb_build_object('ok', true, 'dados', jsonb_build_object('estado', 'rejeitada'));
  end if;

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

create or replace function public.banco_saldo(p_cedula text default null)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cedula text;
  v_conta record;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'erro', 'Sem sessão.');
  end if;

  v_cedula := coalesce(p_cedula, public.fn_minha_cedula());
  if v_cedula is null then
    return jsonb_build_object('ok', false, 'erro', 'Sem ficha na Carteirinha.');
  end if;

  if not (public.fn_e_professor() or public.fn_cedula_minha(v_cedula)) then
    return jsonb_build_object('ok', false, 'erro', 'Sem acesso a esta conta.');
  end if;

  select * into v_conta from public.contas where cedula = v_cedula;
  if not found then
    return jsonb_build_object('ok', false, 'erro', 'Esta cédula ainda não tem conta.');
  end if;

  return jsonb_build_object('ok', true, 'dados', jsonb_build_object(
    'cedula', v_conta.cedula,
    'iban', v_conta.iban,
    'saldo', v_conta.saldo,
    'limite_aprovacao', v_conta.limite_aprovacao,
    'estado', v_conta.estado,
    'pendente_saida', (
      select coalesce(sum(valor), 0) from public.transacoes
      where origem_iban = v_conta.iban and estado = 'pendente'
    )
  ));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Falha ao ler saldo: ' || sqlerrm);
end;
$$;

create or replace function public.banco_extrato(
  p_cedula text default null,
  p_estado text default null,
  p_categoria text default null,
  p_limite int default 50
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_cedula text;
  v_iban text;
  v_linhas jsonb;
begin
  if auth.uid() is null then
    return jsonb_build_object('ok', false, 'erro', 'Sem sessão.');
  end if;

  v_cedula := coalesce(p_cedula, public.fn_minha_cedula());
  if v_cedula is null then
    return jsonb_build_object('ok', false, 'erro', 'Sem ficha na Carteirinha.');
  end if;

  if not (public.fn_e_professor() or public.fn_cedula_minha(v_cedula)) then
    return jsonb_build_object('ok', false, 'erro', 'Sem acesso a esta conta.');
  end if;

  select iban into v_iban from public.contas where cedula = v_cedula;
  if v_iban is null then
    return jsonb_build_object('ok', false, 'erro', 'Esta cédula ainda não tem conta.');
  end if;

  select coalesce(jsonb_agg(linha order by (linha->>'criada_em') desc), '[]'::jsonb)
    into v_linhas
  from (
    select jsonb_build_object(
      'id', t.id,
      'sentido', case when t.origem_iban = v_iban then 'saida' else 'entrada' end,
      'valor', t.valor,
      'categoria', t.categoria,
      'descricao', t.descricao,
      'estado', t.estado,
      'codigo_auth', t.codigo_auth,
      'criada_em', t.criada_em,
      'contraparte', case when t.origem_iban = v_iban then t.destino_iban else coalesce(t.origem_iban, 'emissão') end
    ) as linha
    from public.transacoes t
    where (t.origem_iban = v_iban or t.destino_iban = v_iban)
      and (p_estado is null or t.estado = p_estado)
      and (p_categoria is null or t.categoria = p_categoria)
    order by t.criada_em desc
    limit greatest(coalesce(p_limite, 50), 1)
  ) s;

  return jsonb_build_object('ok', true, 'dados', jsonb_build_object(
    'cedula', v_cedula, 'iban', v_iban, 'movimentos', v_linhas));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Falha ao ler extrato: ' || sqlerrm);
end;
$$;
