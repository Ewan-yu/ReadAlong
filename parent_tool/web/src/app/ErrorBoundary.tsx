import { Component, type ErrorInfo, type ReactNode } from "react";

import styles from "./ErrorBoundary.module.css";

type Props = { children: ReactNode; title?: string };
type State = { error: Error | null };

/** Keeps a failed canvas (Konva init, broken image decode) from white-
 *  screening the whole workbench; the rest of the page stays usable. */
export class ErrorBoundary extends Component<Props, State> {
  state: State = { error: null };

  static getDerivedStateFromError(error: Error): State {
    return { error };
  }

  componentDidCatch(error: Error, info: ErrorInfo) {
    console.error("readalong.web 渲染失败", this.props.title, error, info.componentStack);
  }

  render() {
    if (this.state.error) {
      return (
        <div className={styles.boundary} role="alert">
          <h2>{this.props.title ?? "这一块暂时打不开"}</h2>
          <p>{this.state.error.message || "渲染时出现意外错误。"}</p>
          <button type="button" onClick={() => this.setState({ error: null })}>
            重试
          </button>
        </div>
      );
    }
    return this.props.children;
  }
}
