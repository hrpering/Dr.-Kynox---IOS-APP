import { getSupabaseClient } from "/supabase-client.js";
import { getCachedCaseList, setCachedCaseList } from "/auth-common.js";

function upsertCaseInCache(resultPayload) {
  if (!resultPayload?.sessionId) {
    return;
  }

  const cached = getCachedCaseList(200);
  const mapped = {
    session_id: resultPayload.sessionId,
    mode: resultPayload.mode === "text" ? "text" : "voice",
    status: resultPayload.status || "pending",
    started_at: resultPayload.startedAt || null,
    ended_at: resultPayload.endedAt || null,
    duration_min: Number(resultPayload.durationMin) || null,
    message_count: Number(resultPayload.messageCount) || null,
    difficulty: resultPayload.difficulty || null,
    challenge_id:
      resultPayload.challengeId ||
      resultPayload.caseContext?.challenge_id ||
      resultPayload.caseContext?.challengeId ||
      null,
    challenge_type:
      resultPayload.challengeType ||
      resultPayload.caseContext?.challenge_type ||
      resultPayload.caseContext?.challengeType ||
      null,
    case_context: resultPayload.caseContext || null,
    transcript: Array.isArray(resultPayload.transcript) ? resultPayload.transcript : [],
    score: resultPayload.score || null,
    updated_at: new Date().toISOString()
  };

  const next = [mapped, ...cached.filter((item) => item?.session_id !== mapped.session_id)].slice(0, 200);
  setCachedCaseList(next);
}

export async function syncCaseResultToDb(resultPayload) {
  if (!resultPayload || !resultPayload.sessionId) {
    return false;
  }

  upsertCaseInCache(resultPayload);

  try {
    const supabase = await getSupabaseClient();
    const { data, error } = await supabase.auth.getSession();
    if (error || !data?.session?.access_token) {
      return false;
    }

    const response = await fetch("/api/cases/save", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${data.session.access_token}`
      },
      body: JSON.stringify(resultPayload)
    });

    return response.ok;
  } catch {
    return false;
  }
}
