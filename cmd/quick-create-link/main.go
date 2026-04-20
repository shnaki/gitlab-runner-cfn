package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/url"
	"os"
	"strings"

	"gopkg.in/yaml.v3"
)

type parameter struct {
	ParameterKey   string
	ParameterValue string
}

func loadParams(path string) ([]parameter, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	var params []parameter
	if err := json.NewDecoder(f).Decode(&params); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return params, nil
}

func loadNoEcho(templatePath string) (map[string]bool, error) {
	f, err := os.Open(templatePath)
	if err != nil {
		return nil, err
	}
	defer f.Close()

	var tmpl struct {
		Parameters map[string]map[string]any `yaml:"Parameters"`
	}
	if err := yaml.NewDecoder(f).Decode(&tmpl); err != nil {
		return nil, fmt.Errorf("%s: %w", templatePath, err)
	}

	noEcho := make(map[string]bool)
	for name, props := range tmpl.Parameters {
		switch v := props["NoEcho"].(type) {
		case bool:
			if v {
				noEcho[name] = true
			}
		case string:
			if strings.EqualFold(v, "true") {
				noEcho[name] = true
			}
		}
	}
	return noEcho, nil
}

func buildURL(region, templateS3URL, stackName string, params []parameter, noEcho map[string]bool, warn io.Writer) string {
	base := fmt.Sprintf("https://%s.console.aws.amazon.com/cloudformation/home?region=%s", region, region)
	frag := fmt.Sprintf("/stacks/create/review?templateURL=%s&stackName=%s",
		url.QueryEscape(templateS3URL),
		url.QueryEscape(stackName),
	)
	for _, p := range params {
		if noEcho[p.ParameterKey] {
			if p.ParameterValue != "" {
				fmt.Fprintf(warn, "warning: %s is NoEcho; value omitted from URL (enter manually in console)\n", p.ParameterKey)
			}
			continue
		}
		frag += fmt.Sprintf("&param_%s=%s", p.ParameterKey, url.QueryEscape(p.ParameterValue))
	}
	return base + "#" + frag
}

func s3URL(bucket, prefix, region, filename string) string {
	key := filename
	if prefix != "" {
		key = strings.TrimRight(prefix, "/") + "/" + filename
	}
	return fmt.Sprintf("https://%s.s3.%s.amazonaws.com/%s", bucket, region, key)
}

type result struct {
	Label     string
	URL       string
	Note      string
}

func outputText(results []result, w io.Writer) {
	for _, r := range results {
		fmt.Fprintf(w, "[%s]\n%s\n", r.Label, r.URL)
		if r.Note != "" {
			fmt.Fprintf(w, "NOTE: %s\n", r.Note)
		}
		fmt.Fprintln(w)
	}
}

func outputMarkdown(results []result, w io.Writer) {
	for _, r := range results {
		fmt.Fprintf(w, "- [%s (CloudFormation Quick Create)](%s)\n", r.Label, r.URL)
		if r.Note != "" {
			fmt.Fprintf(w, "  > %s\n", r.Note)
		}
	}
}

func outputJSON(results []result, w io.Writer) {
	type jsonEntry struct {
		Label string `json:"label"`
		URL   string `json:"url"`
		Note  string `json:"note,omitempty"`
	}
	entries := make([]jsonEntry, len(results))
	for i, r := range results {
		entries[i] = jsonEntry{Label: r.Label, URL: r.URL, Note: r.Note}
	}
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	enc.Encode(entries)
}

func main() {
	region := flag.String("region", "ap-northeast-1", "AWS region")
	bucket := flag.String("s3-bucket", "", "S3 bucket hosting the templates (required)")
	prefix := flag.String("s3-prefix", "", "S3 key prefix (e.g. cfn/v1)")
	stackName := flag.String("stack-name", "gitlab-runner", "main stack name")
	iamStackName := flag.String("iam-stack-name", "gitlab-runner-iam", "IAM stack name")
	templateFile := flag.String("template", "gitlab-runner.yaml", "main template filename")
	iamTemplateFile := flag.String("iam-template", "gitlab-runner-iam.yaml", "IAM template filename")
	paramsFile := flag.String("params", "parameters.json", "main parameters JSON")
	iamParamsFile := flag.String("iam-params", "parameters-iam.json", "IAM parameters JSON")
	format := flag.String("format", "text", "output format: text|markdown|json")
	flag.Parse()

	if *bucket == "" {
		fmt.Fprintln(os.Stderr, "error: -s3-bucket is required")
		flag.Usage()
		os.Exit(1)
	}

	iamParams, err := loadParams(*iamParamsFile)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
	mainParams, err := loadParams(*paramsFile)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}

	iamNoEcho, err := loadNoEcho(*iamTemplateFile)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
	mainNoEcho, err := loadNoEcho(*templateFile)
	if err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}

	iamTemplateURL := s3URL(*bucket, *prefix, *region, *iamTemplateFile)
	mainTemplateURL := s3URL(*bucket, *prefix, *region, *templateFile)

	iamURL := buildURL(*region, iamTemplateURL, *iamStackName, iamParams, iamNoEcho, os.Stderr)
	mainURL := buildURL(*region, mainTemplateURL, *stackName, mainParams, mainNoEcho, os.Stderr)

	results := []result{
		{
			Label: "IAM stack (" + *iamStackName + ")",
			URL:   iamURL,
			Note:  "確認画面で「IAM リソース作成の承認」チェックボックスへのチェックが必要 (CAPABILITY_NAMED_IAM)",
		},
		{
			Label: "Main stack (" + *stackName + ")",
			URL:   mainURL,
		},
	}

	switch *format {
	case "markdown":
		outputMarkdown(results, os.Stdout)
	case "json":
		outputJSON(results, os.Stdout)
	default:
		outputText(results, os.Stdout)
	}
}
