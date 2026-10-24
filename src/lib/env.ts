// Environment, validated once. Public values are safe in the browser; server values
// never leave the server (CLAUDE.md §5).
function required(name: string, value: string | undefined): string {
  if (!value) throw new Error(`missing environment variable ${name}`);
  return value;
}

export const publicEnv = {
  supabaseUrl: required("NEXT_PUBLIC_SUPABASE_URL", process.env.NEXT_PUBLIC_SUPABASE_URL),
  supabaseAnonKey: required("NEXT_PUBLIC_SUPABASE_ANON_KEY", process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY),
};

export function serverEnv() {
  return {
    serviceRoleKey: required("SUPABASE_SERVICE_ROLE_KEY", process.env.SUPABASE_SERVICE_ROLE_KEY),
    siteUrl: required("SITE_URL", process.env.SITE_URL),
    smtpHost: required("SMTP_HOST", process.env.SMTP_HOST),
    smtpPort: Number(required("SMTP_PORT", process.env.SMTP_PORT)),
    smtpUser: process.env.SMTP_USER,
    smtpPassword: process.env.SMTP_PASSWORD,
    mailFrom: required("MAIL_FROM", process.env.MAIL_FROM),
  };
}
