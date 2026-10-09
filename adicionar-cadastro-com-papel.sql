-- =====================================================================
--  Cadastro com tipo de conta (tela de entrada do Perfil de Sondagem)
--  Cole este arquivo inteiro no SQL Editor do Supabase e clique em "Run".
--  Pode rodar de novo sem problema. Não apaga dados.
--  Rode DEPOIS do 05_papeis_e_equipe.sql.
--
--  Na hora de criar a conta, a pessoa escolhe:
--   - Administrador: cria a empresa dela (nome informado no cadastro) e já
--     entra como administradora, sem esperar ninguém liberar.
--   - Técnico: a conta fica aguardando; o administrador da empresa adiciona
--     a pessoa pela tela Equipe do WebGeo.
--  Ninguém consegue se colocar como administrador de uma empresa que já existe.
-- =====================================================================

create or replace function wg_empresa_no_cadastro() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  v_org  uuid;
  v_nome text := nullif(trim(new.raw_user_meta_data->>'empresa'), '');
begin
  if coalesce(new.raw_user_meta_data->>'tipo_conta', '') = 'admin' and v_nome is not null then
    insert into organizations (name) values (left(v_nome, 200)) returning id into v_org;
    perform set_config('wg.mudanca_autorizada', 'sim', true);
    insert into profiles (id, full_name, organization_id, role)
    values (new.id, coalesce(new.raw_user_meta_data->>'full_name', ''), v_org, 'admin')
    on conflict (id) do update set organization_id = excluded.organization_id, role = 'admin';
  end if;
  return new;
end $$;

-- roda depois do on_auth_user_created do Perfil (que cria o profile vazio)
drop trigger if exists wg_empresa_no_cadastro on auth.users;
create trigger wg_empresa_no_cadastro after insert on auth.users
  for each row execute function wg_empresa_no_cadastro();
