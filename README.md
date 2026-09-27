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
├── web/          # Web 工作台（AI Storyboard Pro，Python）
│   ├── app.py        # Gradio UI
│   ├── api_server.py # FastAPI REST 服务
│   ├── setup_wizard.py
│   └── mobile/       # Web 端配套 Flutter 移动应用
├── docs/         # 设计文档（视频生成流程、人物一致性方案等）
└── images/       # 演示与宣传素材
```

## 快速开始

### 移动端（Flutter）

```bash
flutter pub get
flutter run
```

### Web 工作台（Python）

```bash
cd web
pip install -r requirements.txt
python setup_wizard.py   # 配置 API Key
./start.sh               # 启动 Gradio UI
```

## 设计文档

- [视频生成完整流程](docs/视频生成完整流程.md)
- [图像生成 API 接口文档](docs/图像生成API接口文档.md)
- [人物一致性实现方案](docs/人物一致性实现方案.md)
- [需求和待办](docs/需求和待办/TODO.md)

## 说明

本仓库为 `freestylefly/director_ai` 的二次开发 fork，上游项目已停止维护（最后提交 2026-05-01），本仓库独立演进。