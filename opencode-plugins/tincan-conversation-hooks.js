export const TincanConversationHooks = async ({ client }) => {
  const callbackUrl =
    process.env.TINCAN_OPENCODE_HOOK_URL ||
    "http://127.0.0.1:8004/hooks/opencode"

  async function publish(payload) {
    try {
      const response = await fetch(callbackUrl, {
        method: "POST",
        headers: {
          "content-type": "application/json",
        },
        body: JSON.stringify(payload),
      })

      if (response.ok) return

      await client.app.log({
        body: {
          service: "tincan-opencode-hooks",
          level: "warn",
          message: `Hook publish failed with HTTP ${response.status}`,
          extra: payload,
        },
      })
    } catch (error) {
      await client.app.log({
        body: {
          service: "tincan-opencode-hooks",
          level: "error",
          message: error instanceof Error ? error.message : String(error),
          extra: payload,
        },
      })
    }
  }

  return {
    event: async ({ event }) => {
      if (event.type === "session.status") {
        await publish({
          event_type: event.type,
          session_id: event.properties.sessionID,
          status_type: event.properties.status.type,
        })
        return
      }

      if (event.type === "session.idle") {
        await publish({
          event_type: event.type,
          session_id: event.properties.sessionID,
          status_type: "idle",
        })
        return
      }

      if (event.type === "session.error") {
        await publish({
          event_type: event.type,
          session_id: event.properties.sessionID,
          error_name: event.properties.error?.name,
          error_message: event.properties.error?.data?.message,
        })
      }
    },
  }
}
