# AI 漫剧制作 APP（director_ai）

一键生成剧本、分镜及合成视频，让你在手机上也能快速制作漫剧。

> 本项目由 [词元 API](https://ciyuan.today) 提供赞助支持。词元 API 是一个 AI 聚合平台，可以高性价比使用 GPT Image 2、nano banana 等国际顶尖模型。

## 项目结构

```
director_ai/
├── lib/          # Flutter 移动端（AI 漫导 Agent）
│   ├── models/       # 剧本、分镜、会话等数据模型
│   ├── services/     # API 服务封装、剧本解析、视频合并
│   ├── providers/    # 状态管理（Provider）
│   ├── screens/      # 对话、剧本预览、素材包等界面
│   └── widgets/      # 通用组件
└── android/      # Android 平台工程
```

## 快速开始

```bash
flutter pub get
flutter run
```

## 核心能力

- 智能对话：以 GLM 大模型作为决策引擎，将自然语言转化为剧本
- 剧本规划：剧本、分镜（生图提示词、视频动效提示词）自动生成与解析
- 人物一致性：保持跨分镜的人物特征一致
- 批量生图 / 生视频：分镜关键帧与动态短片自动生成
- 视频合并：多分镜合成成片

## 说明

本仓库为 `freestylefly/director_ai` 的二次开发 fork，上游项目已停止维护（最后提交 2026-05-01），本仓库独立演进，专注移动端。