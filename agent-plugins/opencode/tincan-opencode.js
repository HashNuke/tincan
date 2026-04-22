export const TincanConversationHooks = async ({ client }) => {
  const server = process.env.TINCAN_SERVER
  const conversationId = process.env.TINCAN_CONVERSATION_ID

  if (!server || !conversationId) {
    return {
      event: async () => {},
    }
  }

  const callbackUrl = new URL("/hooks/opencode", server).toString()

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
      if (event.type === "message.part.updated") {
        const part = event.properties.part
        if (part?.type !== "text" || !part?.time?.end || !part?.text?.trim()) {
          return
        }
        await publish({
          conversation_id: conversationId,
          event_type: event.type,
          session_id: part.sessionID,
          message_id: part.messageID,
          part_id: part.id,
          text: part.text,
        })
        return
      }

      if (event.type === "session.status") {
        await publish({
          conversation_id: conversationId,
          event_type: event.type,
          session_id: event.properties.sessionID,
          status_type: event.properties.status.type,
        })
        return
      }

      if (event.type === "session.idle") {
        await publish({
          conversation_id: conversationId,
          event_type: event.type,
          session_id: event.properties.sessionID,
          status_type: "idle",
        })
        return
      }

      if (event.type === "session.error") {
        await publish({
          conversation_id: conversationId,
          event_type: event.type,
          session_id: event.properties.sessionID,
          error_name: event.properties.error?.name,
          error_message: event.properties.error?.data?.message,
        })
      }
    },
  }
}
