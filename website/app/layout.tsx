import type { Metadata } from "next";
import { Fredoka, Nunito } from "next/font/google";
import "./globals.css";

const display = Fredoka({ subsets: ["latin"], weight: ["500", "600", "700"], variable: "--font-display" });
const body = Nunito({ subsets: ["latin"], weight: ["400", "600", "700"], variable: "--font-body" });

const siteUrl = process.env.VERCEL_PROJECT_PRODUCTION_URL
  ? `https://${process.env.VERCEL_PROJECT_PRODUCTION_URL}`
  : "http://localhost:3000";

export const metadata: Metadata = {
  metadataBase: new URL(siteUrl),
  title: "Kuhtake – Live-Feed-Recorder für die Menüleiste",
  description:
    "Kuhtake filmt den Live-Feed vom Set mit – per Klick oder automatisch über die REC-Anzeige – und legt jeden Take sauber nach Szene, Shot und Take ab. Für macOS.",
  openGraph: {
    title: "Kuhtake",
    description: "Der süßeste Take-Recorder fürs Filmset. Für macOS.",
    images: ["/kuhtake-icon.png"],
  },
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="de" className={`${display.variable} ${body.variable}`}>
      <body>{children}</body>
    </html>
  );
}
