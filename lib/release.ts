export const REPO = "skyks030/kuhtake";
export const RELEASES_URL = `https://github.com/${REPO}/releases/latest`;
export const REPO_URL = `https://github.com/${REPO}`;

export type LatestRelease = {
  version: string | null;
  dmgUrl: string;
  publishedAt: string | null;
};

type GitHubRelease = {
  tag_name: string;
  published_at: string;
  assets: { name: string; browser_download_url: string }[];
};

/** Latest GitHub release, re-checked at most every 5 minutes. Falls back to the releases page. */
export async function getLatestRelease(): Promise<LatestRelease> {
  try {
    const res = await fetch(`https://api.github.com/repos/${REPO}/releases/latest`, {
      headers: { Accept: "application/vnd.github+json" },
      next: { revalidate: 300 },
    });
    if (!res.ok) throw new Error(`GitHub ${res.status}`);
    const release = (await res.json()) as GitHubRelease;
    const dmg = release.assets.find((a) => a.name.toLowerCase().endsWith(".dmg"));
    return {
      version: release.tag_name.replace(/^v/i, ""),
      dmgUrl: dmg?.browser_download_url ?? RELEASES_URL,
      publishedAt: release.published_at,
    };
  } catch {
    return { version: null, dmgUrl: RELEASES_URL, publishedAt: null };
  }
}
