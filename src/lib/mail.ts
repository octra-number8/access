import "server-only";
import nodemailer from "nodemailer";
import { serverEnv } from "./env";

// The app's own emails (invitations). Sign-in codes are sent by Supabase Auth.
export async function sendMail(to: string, subject: string, text: string): Promise<{ ok: true } | { ok: false; error: string }> {
  const env = serverEnv();
  const transport = nodemailer.createTransport({
    host: env.smtpHost,
    port: env.smtpPort,
    secure: env.smtpPort === 465,
    auth: env.smtpUser ? { user: env.smtpUser, pass: env.smtpPassword } : undefined,
  });
  try {
    await transport.sendMail({ from: env.mailFrom, to, subject, text });
    return { ok: true };
  } catch (e) {
    return { ok: false, error: (e as Error).message };
  }
}
