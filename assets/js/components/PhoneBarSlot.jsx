/**
 * The phone top bar's slot.
 *
 * The bar is the layout's (`PhoneTopBar`, above `main`), but the chat page's
 * chrome — the agent's name, its status dot, the disclosure and the waiting
 * badge — belongs to the page. So the bar exposes a slot and the page fills it,
 * through a portal: the bar keeps owning the hamburger, the safe-area inset and
 * the border, and the page keeps owning the state, with no second copy of either.
 *
 * `null` when there is no slot (a desktop render, or a test with no layout
 * around it): the caller then renders its chrome inline, which is what the
 * page did before there was a bar to put it in.
 */
import { createContext, useContext } from "react";

export const PhoneBarSlotContext = createContext(null);

export function usePhoneBarSlot() {
  return useContext(PhoneBarSlotContext);
}
