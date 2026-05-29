#!/usr/bin/env python3
"""Bake Roy's OpenAI Codex null response.output stream recovery into the image.

This is intentionally narrow and idempotent. It patches /opt/hermes/run_agent.py
inside the Roy image build so the live-container recovery from Kanban task
t_04ead7e0 survives Roy-only rebuilds/recreates.
"""
from pathlib import Path

path = Path("/opt/hermes/run_agent.py")
text = path.read_text()
marker = "response.completed frame whose response.output is null"
if marker in text:
    print("Roy Codex null-output recovery already present")
    raise SystemExit(0)

old_final = """                    final_response = stream.get_final_response()
"""
new_final = """                    try:
                        final_response = stream.get_final_response()
                    except TypeError as exc:
                        # ChatGPT-account Codex sometimes sends a terminal
                        # response.completed frame whose response.output is null.
                        # openai-python tries to iterate it while finalizing the
                        # stream and raises before returning the snapshot.  The
                        # preceding output_item.done / output_text.delta events
                        # are still valid, so recover from the items already
                        # collected in this method instead of surfacing a false
                        # provider/auth failure.
                        if "'NoneType' object is not iterable" not in str(exc):
                            raise
                        if collected_output_items:
                            logger.warning(
                                "Codex stream: SDK finalization hit null output; "
                                "recovering from %d collected output item(s)",
                                len(collected_output_items),
                            )
                            return SimpleNamespace(
                                output=list(collected_output_items),
                                status="completed",
                                model=getattr(self, "model", None),
                                usage=None,
                            )
                        if self._codex_streamed_text_parts and not has_tool_calls:
                            assembled = "".join(self._codex_streamed_text_parts)
                            logger.warning(
                                "Codex stream: SDK finalization hit null output; "
                                "synthesizing response from %d text delta(s)",
                                len(self._codex_streamed_text_parts),
                            )
                            return SimpleNamespace(
                                output=[SimpleNamespace(
                                    type="message",
                                    role="assistant",
                                    status="completed",
                                    content=[SimpleNamespace(type="output_text", text=assembled)],
                                )],
                                status="completed",
                                model=getattr(self, "model", None),
                                usage=None,
                            )
                        raise
"""
if old_final not in text:
    raise SystemExit("Expected get_final_response() line not found; refusing to patch Roy image")
text = text.replace(old_final, new_final, 1)

old_outer = """                    return final_response
            except (_httpx.RemoteProtocolError, _httpx.ReadTimeout, _httpx.ConnectError, ConnectionError) as exc:
"""
new_outer = """                    return final_response
            except TypeError as exc:
                if "'NoneType' object is not iterable" not in str(exc):
                    raise
                if collected_output_items:
                    logger.warning(
                        "Codex stream: SDK iteration hit null output; "
                        "recovering from %d collected output item(s)",
                        len(collected_output_items),
                    )
                    return SimpleNamespace(
                        output=list(collected_output_items),
                        status="completed",
                        model=getattr(self, "model", None),
                        usage=None,
                    )
                if self._codex_streamed_text_parts and not has_tool_calls:
                    assembled = "".join(self._codex_streamed_text_parts)
                    logger.warning(
                        "Codex stream: SDK iteration hit null output; "
                        "synthesizing response from %d text delta(s)",
                        len(self._codex_streamed_text_parts),
                    )
                    return SimpleNamespace(
                        output=[SimpleNamespace(
                            type="message",
                            role="assistant",
                            status="completed",
                            content=[SimpleNamespace(type="output_text", text=assembled)],
                        )],
                        status="completed",
                        model=getattr(self, "model", None),
                        usage=None,
                    )
                raise
            except (_httpx.RemoteProtocolError, _httpx.ReadTimeout, _httpx.ConnectError, ConnectionError) as exc:
"""
if old_outer not in text:
    raise SystemExit("Expected Codex stream outer exception block not found; refusing to patch Roy image")
text = text.replace(old_outer, new_outer, 1)

path.write_text(text)
print("Applied Roy Codex null-output recovery to /opt/hermes/run_agent.py")
