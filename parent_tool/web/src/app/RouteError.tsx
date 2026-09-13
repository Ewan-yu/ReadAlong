import { Link } from "@tanstack/react-router";

import styles from "./RouteError.module.css";

/** Router-level fallback: deep links to deleted books or render errors used
 *  to show the unstyled default error page with no way back. */
export function RouteError({ error }: { error?: unknown }) {
  const message =
    error instanceof Error && error.message
      ? error.message
      : "页面加载出现问题，请从制作历史重新进入。";
  return <RouteErrorView message={message} />;
}

export function RouteNotFound() {
  return <RouteErrorView message="页面不存在或已被移动，请从制作历史重新进入。" />;
}

function RouteErrorView({ message }: { message: string }) {
  return (
    <div className={styles.page} role="alert">
      <div>
        <p>ReadAlong 跟读宝</p>
        <h1>这一页暂时打不开</h1>
        <p className={styles.detail}>{message}</p>
        <div className={styles.actions}>
          <Link to="/books">返回制作历史</Link>
        </div>
      </div>
    </div>
  );
}
