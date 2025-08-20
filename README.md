# DMTools Agentic Workflows

A collection of reusable GitHub workflows and scripts that leverage AI models (Gemini, GPT) for automated code implementation, discovery, and assistance. Designed for multi-repository use with customizable prompts and flexible configuration.

## 🚀 Features

- **🤖 Gemini CLI Integration**: Automated code implementation and discovery workflows
- **🔧 Aider Integration**: AI-powered code assistance and refactoring
- **📝 Customizable Prompts**: Override default prompts with project-specific rules
- **🔄 Automated PR Creation**: Intelligent branch naming and pull request generation
- **🛠️ Git Workflow Automation**: Commit message generation and branch management
- **📊 Comprehensive Logging**: Detailed execution logs and artifact generation
- **🎯 Multi-Model Support**: Gemini 2.0/2.5, Aider with various AI models

## 📁 Repository Structure

```
dmtools-agentic-workflows/
├── .github/
│   └── workflows/
│       ├── reusable-gemini-implementation.yml    # AI code implementation
│       ├── reusable-gemini-discovery.yml         # AI code discovery & analysis
│       └── reusable-aider-assist.yml             # AI code assistance
├── scripts/
│   ├── prepare-user-request.sh                   # Request preparation
│   ├── run-gemini.sh                             # Gemini CLI execution
│   ├── run-aider.sh                              # Aider execution
│   ├── git-workflow.sh                           # Git operations automation
│   ├── generate_pr_notes.sh                      # PR metadata generation
│   └── setup-cli-env.sh                          # Environment setup
├── prompts/
│   ├── implementation-prompt.md                  # Default implementation prompt
│   ├── discovery-prompt.md                       # Default discovery prompt
│   ├── assist-prompt.md                          # Default assistance prompt
│   └── pull_request_and_commit.md               # PR generation prompt
├── docs/
│   ├── SETUP.md                                  # Setup instructions
│   ├── USAGE.md                                  # Usage examples
│   └── PROMPT_CUSTOMIZATION.md                  # Prompt customization guide
└── examples/
    ├── basic-usage/                              # Basic integration examples
    ├── custom-prompts/                           # Custom prompt examples
    └── multi-repo-setup/                         # Multi-repository setup
```

## 🏁 Quick Start

### 1. Basic Implementation Workflow

Add this workflow to your repository as `.github/workflows/ai-implementation.yml`:

```yaml
name: AI Code Implementation

on:
  workflow_dispatch:
    inputs:
      user_request:
        description: 'Your coding request'
        required: true
        type: string
      model:
        description: 'Gemini model to use'
        required: false
        type: choice
        default: 'gemini-2.5-flash-preview-05-20'
        options:
          - gemini-2.0-flash-exp
          - gemini-1.5-pro-latest
          - gemini-2.5-flash-preview-05-20

jobs:
  implement:
    uses: IstiN/dmtools-agentic-workflows/.github/workflows/reusable-gemini-implementation.yml@main
    with:
      user_request: ${{ inputs.user_request }}
      model: ${{ inputs.model }}
    secrets:
      GEMINI_API_KEY: ${{ secrets.GEMINI_API_KEY }}
      PAT_TOKEN: ${{ secrets.PAT_TOKEN }}
```

### 2. Basic Discovery Workflow

Add this workflow to your repository as `.github/workflows/ai-discovery.yml`:

```yaml
name: AI Code Discovery

on:
  workflow_dispatch:
    inputs:
      user_request:
        description: 'Your discovery request'
        required: true
        type: string

jobs:
  discover:
    uses: IstiN/dmtools-agentic-workflows/.github/workflows/reusable-gemini-discovery.yml@main
    with:
      user_request: ${{ inputs.user_request }}
    secrets:
      GEMINI_API_KEY: ${{ secrets.GEMINI_API_KEY }}
```

### 3. Basic Aider Assistance Workflow

Add this workflow to your repository as `.github/workflows/ai-assist.yml`:

```yaml
name: AI Code Assistance

on:
  workflow_dispatch:
    inputs:
      user_request:
        description: 'Your assistance request'
        required: true
        type: string
      target_files:
        description: 'Files to analyze (comma-separated)'
        required: false
        type: string

jobs:
  assist:
    uses: IstiN/dmtools-agentic-workflows/.github/workflows/reusable-aider-assist.yml@main
    with:
      user_request: ${{ inputs.user_request }}
      target_files: ${{ inputs.target_files }}
    secrets:
      GEMINI_API_KEY: ${{ secrets.GEMINI_API_KEY }}
```

## 🔧 Advanced Configuration

### Custom Prompts and Rules

You can override default prompts and add project-specific rules:

```yaml
jobs:
  implement:
    uses: IstiN/dmtools-agentic-workflows/.github/workflows/reusable-gemini-implementation.yml@main
    with:
      user_request: ${{ inputs.user_request }}
      custom_implementation_prompt: '.github/prompts/my-implementation-prompt.md'
      custom_rules_file: 'docs/CODING_STANDARDS.md'
      additional_context_files: 'README.md,ARCHITECTURE.md,package.json'
    secrets:
      GEMINI_API_KEY: ${{ secrets.GEMINI_API_KEY }}
      PAT_TOKEN: ${{ secrets.PAT_TOKEN }}
```

### Version Pinning

Pin to a specific version for stability:

```yaml
jobs:
  implement:
    uses: IstiN/dmtools-agentic-workflows/.github/workflows/reusable-gemini-implementation.yml@v1.0.0
    # ... rest of configuration
```

### Custom Workflows Repository

Use a fork or custom repository:

```yaml
jobs:
  implement:
    uses: IstiN/dmtools-agentic-workflows/.github/workflows/reusable-gemini-implementation.yml@main
    with:
      user_request: ${{ inputs.user_request }}
      workflows_repo: 'my-org/custom-agentic-workflows'
      workflows_ref: 'custom-branch'
    secrets:
      GEMINI_API_KEY: ${{ secrets.GEMINI_API_KEY }}
      PAT_TOKEN: ${{ secrets.PAT_TOKEN }}
```

## 🔑 Required Secrets

Set up these secrets in your repository:

### Required for All Workflows
- `GEMINI_API_KEY`: Your Google Gemini API key

### Required for Implementation Workflow
- `PAT_TOKEN`: GitHub Personal Access Token with repo and PR permissions

### Setting Up Secrets

1. Go to your repository settings
2. Navigate to "Secrets and variables" → "Actions"
3. Add the required secrets:
   - **GEMINI_API_KEY**: Get from [Google AI Studio](https://makersuite.google.com/app/apikey)
   - **PAT_TOKEN**: Create from [GitHub Settings](https://github.com/settings/tokens)

## 📝 Available Workflows

### 1. Reusable Gemini Implementation

**File**: `reusable-gemini-implementation.yml`

**Purpose**: Automated code implementation using Gemini CLI

**Features**:
- AI-powered code generation and modification
- Automated PR creation with intelligent branch naming
- Custom prompt support
- Comprehensive logging and debugging

**Key Parameters**:
- `user_request`: Your implementation request
- `model`: Gemini model to use
- `custom_implementation_prompt`: Path to custom prompt file
- `custom_rules_file`: Path to project-specific rules
- `additional_context_files`: Comma-separated list of context files

### 2. Reusable Gemini Discovery

**File**: `reusable-gemini-discovery.yml`

**Purpose**: AI-powered code analysis and discovery

**Features**:
- Codebase exploration and understanding
- Architecture analysis
- Documentation generation
- Issue identification

**Key Parameters**:
- `user_request`: Your discovery question
- `model`: Gemini model to use
- `custom_discovery_prompt`: Path to custom discovery prompt
- `custom_rules_file`: Path to project-specific rules

### 3. Reusable Aider Assist

**File**: `reusable-aider-assist.yml`

**Purpose**: AI-powered code assistance and refactoring

**Features**:
- Code review and suggestions
- Refactoring assistance
- Bug fix recommendations
- Code quality improvements

**Key Parameters**:
- `user_request`: Your assistance request
- `target_files`: Specific files to analyze
- `model`: AI model to use with Aider
- `max_tokens`: Maximum context tokens

## 🎯 Use Cases

### 1. Feature Implementation
```yaml
# Trigger: Manual workflow dispatch
user_request: "Implement user authentication with JWT tokens"
```

### 2. Bug Analysis
```yaml
# Trigger: Manual workflow dispatch
user_request: "Analyze the login failure issue in the authentication module"
target_files: "src/auth/login.js,src/auth/jwt.js"
```

### 3. Code Discovery
```yaml
# Trigger: Manual workflow dispatch
user_request: "How does the payment processing system work?"
```

### 4. Architecture Review
```yaml
# Trigger: Manual workflow dispatch
user_request: "Review the current microservices architecture and suggest improvements"
additional_context_files: "ARCHITECTURE.md,docker-compose.yml,k8s/"
```

## 📊 Outputs and Artifacts

All workflows generate comprehensive artifacts:

### Implementation Workflow
- **PR Creation**: Automated pull request with implementation
- **Artifacts**: `agentic-workflow-results-{run_number}`
  - Implementation response
  - Execution logs
  - PR metadata
  - Combined prompts

### Discovery Workflow
- **Analysis Report**: Detailed discovery analysis
- **Artifacts**: `agentic-discovery-results-{run_number}`
  - Discovery response
  - Full report
  - Execution logs

### Assistance Workflow
- **Analysis Summary**: Code assistance recommendations
- **Artifacts**: `agentic-aider-results-{run_number}`
  - Assistance response
  - Analysis summary
  - Execution logs

## 🛠️ Customization

### Creating Custom Prompts

1. Create a prompts directory in your repository:
```
your-repo/
├── .github/
│   └── prompts/
│       ├── my-implementation-prompt.md
│       ├── my-discovery-prompt.md
│       └── project-rules.md
```

2. Reference them in your workflow:
```yaml
with:
  custom_implementation_prompt: '.github/prompts/my-implementation-prompt.md'
  custom_rules_file: '.github/prompts/project-rules.md'
```

### Custom Rules Example

Create a `project-rules.md` file:

```markdown
# Project-Specific Rules

## Architecture Guidelines
- Use TypeScript strict mode
- Follow React functional components pattern
- Implement proper error boundaries

## Testing Requirements
- Write unit tests for all business logic
- Use Jest and React Testing Library
- Maintain 80%+ code coverage

## Code Style
- Use ESLint and Prettier
- Follow conventional commits
- Use meaningful variable names
```

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test with your own repository
5. Submit a pull request

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

## 🔗 Related Resources

- [DMTools Main Repository](https://github.com/IstiN/dmtools)
- [Gemini CLI Documentation](https://github.com/google/gemini-cli)
- [Aider Documentation](https://aider.chat/)
- [GitHub Actions Documentation](https://docs.github.com/en/actions)

## 📞 Support

- **Issues**: [GitHub Issues](https://github.com/IstiN/dmtools-agentic-workflows/issues)
- **Discussions**: [GitHub Discussions](https://github.com/IstiN/dmtools-agentic-workflows/discussions)
- **Documentation**: [Wiki](https://github.com/IstiN/dmtools-agentic-workflows/wiki)

---

**Made with ❤️ by the DMTools team**
