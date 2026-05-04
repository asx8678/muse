Sure, I can help with that! Here's the structured plan:

{
  "objective": "Refactor the event stream module for back-pressure support.",
  "summary": "Add GenStage-based back-pressure to Muse.EventStream.",
  "tasks": [
    {
      "title": "Add GenStage producer",
      "description": "Wrap EventStream as a GenStage producer.",
      "requires_write": true,
      "requires_shell": false
    },
    {
      "title": "Add consumer supervisor",
      "description": "Create a DemandConsumer that applies back-pressure.",
      "requires_write": true,
      "requires_shell": true
    }
  ],
  "risks": [
    "GenStage may add latency for low-throughput sessions."
  ]
}

Let me know if this plan works for you.
