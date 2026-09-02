-- Prepacoin — a conta passa a nascer com a cédula.
--
-- Até aqui `id_registar_pessoa` e `id_registar_empresa` só criavam a
-- ficha na Carteirinha; a conta bancária tinha de ser aberta à parte
-- (era o que o painel "Ainda não tem conta" do Prepacoin cobria). No
-- desenho original quem juntava as duas coisas era o `pp-criar-empresa`,
-- que ainda não existe. Decisão do Germano (2026-09-02): cada pessoa e
-- cada empresa já nasce com conta.
--
-- ## Limite de aprovação
--
-- Pedido: "se a pessoa for gerente ele deve aprovar valores acima de
-- 1000 Prepacoin". Isso é governança do dinheiro **da empresa**, por
-- isso:
--   • conta de empresa (`EP-…`) → limite 100000 cêntimos = P$ 1 000,00;
--     acima disso a transferência fica pendente até um gerente aprovar.
--   • conta de pessoa (`PP-…`)  → sem limite.
-- A conta pessoal não pode ter limite: `banco_decidir_pendente` só deixa
-- decidir um gerente da empresa dona da conta de origem, e uma conta
-- pessoal não tem gerente — uma pendente ali ficaria presa para sempre,
-- sem ninguém com poder de a aprovar.
--
-- ## Porquê uma função interna
--
-- `banco_abrir_conta` valida quem está a chamar (professor, o próprio
-- titular, ou alguém da empresa). No momento do registo essa validação
-- não serve: a pessoa que está a ser criada ainda não tem sessão, e a
-- cédula ainda não é de ninguém. Daí `banco_criar_conta_interna`, sem
-- checagem de chamador e revogada de PUBLIC — só corre de dentro de
-- outra função SECURITY DEFINER. `banco_abrir_conta` passa a ser a
-- porta pública que valida e delega.
--
-- ## Falhar a abrir conta não pode partir o registo
--
-- A identidade é mais fundamental que a conta: se o banco falhar, a
-- pessoa tem de ficar registada na mesma. Por isso a chamada vai num
-- sub-bloco `begin … exception … end` próprio — em plpgsql isso é uma
-- subtransação, e um erro lá dentro desfaz só essa parte, não o registo.
-- A resposta passa a incluir `iban` (ou `aviso_banco`, se falhou).
--
-- Aplicada ao Supabase do projeto (moxxbehwylcjaqjacmyh) em 2026-09-02.

-- ---------------------------------------------------------------------
-- Criação de conta sem checagem de chamador (uso interno)
-- ---------------------------------------------------------------------
create or replace function public.banco_criar_conta_interna(
  p_cedula text,
  p_limite bigint default null
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
  if p_cedula is null or btrim(p_cedula) = '' then
    return jsonb_build_object('ok', false, 'erro', 'Cédula obrigatória.');
  end if;

  -- idempotente: se já existe, devolve a que está lá (R8 da pp-base)
  select iban into v_existe from public.contas where cedula = p_cedula;
  if v_existe is not null then
    return jsonb_build_object('ok', true, 'dados', jsonb_build_object('iban', v_existe, 'nova', false));
  end if;

  v_iban := public.fn_gerar_iban(p_cedula);
  insert into public.contas(cedula, iban, limite_aprovacao)
  values (p_cedula, v_iban, p_limite);

  return jsonb_build_object('ok', true, 'dados', jsonb_build_object('iban', v_iban, 'nova', true));
end;
$$;

revoke execute on function public.banco_criar_conta_interna(text, bigint)
  from public, anon, authenticated;

-- ---------------------------------------------------------------------
-- Porta pública: valida quem chama e delega
-- ---------------------------------------------------------------------
create or replace function public.banco_abrir_conta(
  p_cedula text,
  p_limite bigint default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_limite bigint;
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
  if not (public.id_resolver(p_cedula)->>'ok')::boolean then
    return jsonb_build_object('ok', false, 'erro', 'Cédula inexistente: ' || p_cedula);
  end if;

  -- empresa entra com o limite de aprovação; pessoa fica sem limite
  v_limite := coalesce(p_limite, case when p_cedula like 'EP-%' then 100000 else null end);

  return public.banco_criar_conta_interna(p_cedula, v_limite);
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Falha ao abrir conta: ' || sqlerrm);
end;
$$;

-- ---------------------------------------------------------------------
-- Registo de pessoa → conta pessoal (sem limite de aprovação)
-- ---------------------------------------------------------------------
create or replace function public.id_registar_pessoa(
  p_nome text,
  p_email_login text,
  p_senha text,
  p_email_interno text,
  p_papel text default 'aluno'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_existente record;
  v_novo_uid uuid;
  v_cedula text;
  v_banco jsonb;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'erro', 'Sem sessão.');
  end if;
  if not exists (select 1 from public.pessoas where id = v_uid and papel = 'professor') then
    return jsonb_build_object('ok', false, 'erro', 'Só o professor/admin regista pessoas.');
  end if;
  if coalesce(p_nome,'') = '' or coalesce(p_email_login,'') = '' or coalesce(p_senha,'') = '' then
    return jsonb_build_object('ok', false, 'erro', 'Dados obrigatórios em falta.');
  end if;
  if length(p_senha) < 6 then
    return jsonb_build_object('ok', false, 'erro', 'Senha precisa de pelo menos 6 caracteres.');
  end if;

  select * into v_existente from public.pessoas where email_login = p_email_login;
  if found then
    -- idempotente: garante a conta mesmo para quem foi registado antes
    begin
      v_banco := public.banco_criar_conta_interna(v_existente.cedula, null);
    exception when others then
      v_banco := jsonb_build_object('ok', false, 'erro', sqlerrm);
    end;
    return jsonb_build_object('ok', true, 'dados', jsonb_build_object(
      'cedula', v_existente.cedula,
      'iban', v_banco->'dados'->>'iban'));
  end if;

  select id into v_novo_uid from auth.users where email = p_email_login;
  if v_novo_uid is null then
    v_novo_uid := gen_random_uuid();
    insert into auth.users (
      instance_id, id, aud, role, email, encrypted_password,
      email_confirmed_at, created_at, updated_at,
      raw_app_meta_data, raw_user_meta_data,
      is_super_admin, confirmation_token, recovery_token,
      email_change_token_new, email_change, is_sso_user, is_anonymous
    ) values (
      '00000000-0000-0000-0000-000000000000',
      v_novo_uid, 'authenticated', 'authenticated', p_email_login,
      extensions.crypt(p_senha, extensions.gen_salt('bf')),
      now(), now(), now(),
      '{"provider":"email","providers":["email"]}'::jsonb, '{}'::jsonb,
      false, '', '', '', '', false, false
    );
    insert into auth.identities (
      id, provider_id, user_id, identity_data, provider, last_sign_in_at, created_at, updated_at
    ) values (
      gen_random_uuid(), v_novo_uid::text, v_novo_uid,
      jsonb_build_object('sub', v_novo_uid::text, 'email', p_email_login, 'email_verified', true),
      'email', now(), now(), now()
    );
  end if;

  v_cedula := public.fn_proxima_cedula('PP');
  insert into public.pessoas(id, cedula, nome, email_login, email_interno, papel)
  values (v_novo_uid, v_cedula, p_nome, p_email_login, p_email_interno, coalesce(p_papel, 'aluno'));

  -- conta pessoal, sem limite: não há gerente que aprove numa conta de pessoa
  begin
    v_banco := public.banco_criar_conta_interna(v_cedula, null);
  exception when others then
    v_banco := jsonb_build_object('ok', false, 'erro', sqlerrm);
  end;

  return jsonb_build_object('ok', true, 'dados', jsonb_build_object(
    'cedula', v_cedula,
    'email_login', p_email_login,
    'iban', v_banco->'dados'->>'iban',
    'aviso_banco', case when (v_banco->>'ok')::boolean then null
                        else 'Pessoa registada, mas a conta não foi aberta: ' || (v_banco->>'erro') end));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Falha ao registar pessoa.');
end;
$$;

-- ---------------------------------------------------------------------
-- Registo de empresa → conta com limite de aprovação de P$ 1 000,00
-- ---------------------------------------------------------------------
create or replace function public.id_registar_empresa(
  p_nome text,
  p_email_empresa text,
  p_regiao text,
  p_setor text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_uid uuid := auth.uid();
  v_existente record;
  v_cedula text;
  v_nif text;
  v_banco jsonb;
begin
  if v_uid is null then
    return jsonb_build_object('ok', false, 'erro', 'Sem sessão.');
  end if;
  if not exists (select 1 from public.pessoas where id = v_uid and papel = 'professor') then
    return jsonb_build_object('ok', false, 'erro', 'Só o professor/admin regista empresas.');
  end if;
  if coalesce(p_nome,'') = '' then
    return jsonb_build_object('ok', false, 'erro', 'Nome é obrigatório.');
  end if;

  if p_email_empresa is not null then
    select * into v_existente from public.empresas where email_empresa = p_email_empresa;
    if found then
      begin
        v_banco := public.banco_criar_conta_interna(v_existente.cedula, 100000);
      exception when others then
        v_banco := jsonb_build_object('ok', false, 'erro', sqlerrm);
      end;
      return jsonb_build_object('ok', true, 'dados', jsonb_build_object(
        'cedula', v_existente.cedula,
        'nif_ficticio', v_existente.nif_ficticio,
        'iban', v_banco->'dados'->>'iban'));
    end if;
  end if;

  v_cedula := public.fn_proxima_cedula('EP');
  v_nif := regexp_replace(v_cedula, '\D', '', 'g');
  insert into public.empresas(cedula, nome, nif_ficticio, email_empresa, regiao, setor)
  values (v_cedula, p_nome, v_nif, p_email_empresa, p_regiao, p_setor);

  -- P$ 1 000,00: acima disto, a transferência espera aprovação de um gerente
  begin
    v_banco := public.banco_criar_conta_interna(v_cedula, 100000);
  exception when others then
    v_banco := jsonb_build_object('ok', false, 'erro', sqlerrm);
  end;

  return jsonb_build_object('ok', true, 'dados', jsonb_build_object(
    'cedula', v_cedula,
    'nif_ficticio', v_nif,
    'iban', v_banco->'dados'->>'iban',
    'limite_aprovacao', 100000,
    'aviso_banco', case when (v_banco->>'ok')::boolean then null
                        else 'Empresa registada, mas a conta não foi aberta: ' || (v_banco->>'erro') end));
exception when others then
  return jsonb_build_object('ok', false, 'erro', 'Falha ao registar empresa.');
end;
$$;
