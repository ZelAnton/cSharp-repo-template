namespace __ProjectName__.Tests;

[TestFixture]
public class GreeterTests
{
	[Test]
	public void Greet_ReturnsGreetingWithName()
	{
		Assert.That(Greeter.Greet("World"), Is.EqualTo("Hello, World!"));
	}
}
