# OpenWrt AI Support Application - aihelper
This application is currently under development...

## Commands
> [!IMPORTANT]
> Some commands may not be available.

```
root@OpenWrt:~# aihelper
Usage: aihelper <command> [[<options>] arguments]...

Options:
 -n <service>           Set the service name
 -u <url>               Set the url or ipaddr for ai service
 -k <api-key>           Set the api-key for ai service
 -m <model>             Set the llm model for ai service
 -s enable or disable   Set the storage enable/disable

Commands:
 - storage <path> [<chat-max>] (default: chat-max = 30)
 - add [<service> [<url> [<api-key> [<model> [<storage>]]]]]
 - change <service> [<options> <argument>]...
 - select [<service>]
 - delete <service>
 - chat [id=<chat-id>]
 - prompt
 - delchat <id>
 - rename <id> <title>
 - list [[chat] [knowledge]]
 - test <service>
 - call <script> <messsage>

Docs
        https://utakamo.com
```
## Usage
### Step1: Setting up ai service  
- Example of local ai service (Ollama) 
```
root@OpenWrt:~# aihelper add
Service Name                   >> my-ollama
Endpoint(url)                  >> http://192.168.3.12:11434/api/chat       
API KEY (leave blank if none)  >>
LLM MODEL                      >> gemma2:2b
``````
- Example of chatgpt
```
Service Name                   >> my-chatgpt
Endpoint(url)                  >> https://api.openai.com/v1/chat/completions
API KEY (leave blank if none)  >> <your_api-key>
LLM MODEL                      >> gpt-3.5-turbo
```
> [!NOTE]
> If you want to use chatgpt, you need to set the Endpoint to the following URL.
> https://api.openai.com/v1/chat/completions  

### Step2: Example of chat with ai
```
root@OpenWrt:~# aihelper chat
You :Hello!

gemma2:2b
Hello! 👋  

How can I help you today? 😄
```
End the chat --> type 'exit'  
Display the chat history --> type 'show'
# Dependency Package
- lua-curl-v3
