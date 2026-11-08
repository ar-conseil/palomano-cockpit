// Projet Supabase de l'espace équipe — ces deux valeurs sont publiques par conception :
// la sécurité repose sur les règles d'accès de la base (voir schema.sql), pas sur leur secret.
// Ne jamais mettre ici la clé « service_role ».
window.PALO_CONFIG = {
  supabaseUrl: "",
  supabaseAnonKey: "",
};
