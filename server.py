from fastmcp import FastMCP

mcp = FastMCP(
    name="Arithmetic MCP Server",
    instructions="A simple arithmetic MCP server that provides basic math operations: add, subtract, multiply, and divide.",
)


@mcp.tool
def add(a: float, b: float) -> float:
    """Add two numbers together and return the result."""
    return a + b


@mcp.tool
def subtract(a: float, b: float) -> float:
    """Subtract b from a and return the result."""
    return a - b


@mcp.tool
def multiply(a: float, b: float) -> float:
    """Multiply two numbers together and return the result."""
    return a * b


@mcp.tool
def divide(a: float, b: float) -> float:
    """Divide a by b and return the result. Raises an error if b is zero."""
    if b == 0:
        raise ValueError("Cannot divide by zero.")
    return a / b


@mcp.tool
def modulo(a: float, b: float) -> float:
    """Return the remainder of dividing a by b."""
    if b == 0:
        raise ValueError("Cannot perform modulo with zero divisor.")
    return a % b


@mcp.tool
def power(base: float, exponent: float) -> float:
    """Raise base to the power of exponent and return the result."""
    return base ** exponent


if __name__ == "__main__":
    import os

    transport = os.environ.get("MCP_TRANSPORT", "stdio")
    if transport == "streamable-http":
        mcp.run(
            transport="streamable-http",
            host=os.environ.get("HOST", "0.0.0.0"),
            port=int(os.environ.get("PORT", "8000")),
        )
    else:
        mcp.run()
