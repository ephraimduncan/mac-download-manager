from google import genai

client = genai.Client(

    vertexai=True,

    project="project-2e0b3904-c0a4-481d-bb9"

)

response = client.models.generate_content(

    model="gemini-3.1-flash-lite-preview",

    contents="Hello! What can you do?"

)

print(response.text)
