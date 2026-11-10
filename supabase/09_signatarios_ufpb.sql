-- DESTINA — signatários atuais da UFPB (Reitoria e Pró-Reitoria de Administração)
update public.config
   set dados = jsonb_set(jsonb_set(dados,
         '{signatarios,REITORIA}', jsonb_build_object('nome', 'Terezinha Domiciano', 'cargo', 'Reitora')),
         '{signatarios,PRA}', jsonb_build_object('nome', 'George Beltrão', 'cargo', 'Pró-Reitor de Administração')),
       atualizado_em = now()
 where id = 1;
